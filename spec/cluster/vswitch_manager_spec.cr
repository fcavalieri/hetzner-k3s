require "../spec_helper"
require "../../src/configuration/main"
require "../../src/cluster/vswitch_manager"

alias RVS = Hetzner::Robot::Client::VSwitch
alias RVSS = Hetzner::Robot::Client::VSwitchServer

class FakeRobotClient < Hetzner::Robot::Client
  getter calls = [] of String
  property data : Array(RVS)
  property statuses : Array(String)   # consumed one per vswitch(id) call, last one repeats

  def initialize(@data = [] of RVS, @statuses = ["ready"])
    super("u", "p")
  end

  def vswitches : Array(RVS)
    calls << "list"
    data.map { |v| RVS.new(v.id, v.name, v.vlan, [] of RVSS, v.cancelled) }
  end

  # Unknown ids fail the way Robot does: HTTP 404 with code NOT_FOUND in the body.
  def vswitch(id : Int32) : RVS
    calls << "get #{id}"
    found = data.find { |v| v.id == id } || raise Hetzner::Robot::Client::Error.new(%(Failed to fetch Robot vSwitch #{id}: {"error":{"status":404,"code":"NOT_FOUND","message":"vSwitch not found"}}))
    status = statuses.size > 1 ? statuses.shift : statuses.first
    RVS.new(found.id, found.name, found.vlan, found.servers.map { |s| RVSS.new(s.number, status) }, found.cancelled)
  end

  def create_vswitch(name : String, vlan : Int32) : RVS
    calls << "create #{name} #{vlan}"
    created = RVS.new(4321, name, vlan, [] of RVSS)
    data << created
    created
  end

  property vlan_busy_rejections = 0   # how many attach calls still fail with 409 VSWITCH_VLAN_NOT_UNIQUE

  def add_vswitch_servers(id : Int32, numbers : Array(Int32)) : Nil
    calls << "add #{id} #{numbers.join(",")}"
    if vlan_busy_rejections > 0
      self.vlan_busy_rejections -= 1
      raise Hetzner::Robot::Client::Error.new(%(Failed to add server(s) #{numbers.join(", ")} to Robot vSwitch #{id}: {"error":{"status":409,"code":"VSWITCH_VLAN_NOT_UNIQUE","message":"vlan of vswitch is already in use at server Server Auction ##{numbers.first}, please change vlan"}}))
    end
    data.find { |v| v.id == id }.not_nil!.servers.concat(numbers.map { |n| RVSS.new(n, "in process") })
  end

  def remove_vswitch_servers(id : Int32, numbers : Array(Int32)) : Nil
    calls << "remove #{id} #{numbers.join(",")}"
  end

  def delete_vswitch(id : Int32) : Nil
    calls << "delete #{id}"
  end
end

def manager_settings(extra_vswitch = "") : Configuration::Main
  Configuration::Main.from_yaml(<<-YAML
  hetzner_token: x
  cluster_name: test
  kubeconfig_path: /tmp/kubeconfig
  k3s_version: v1.36.1+k3s1
  masters_pool:
    instance_type: cx22
    instance_count: 1
    locations: [fsn1]
  networking:
    private_network:
      ip_range: 10.0.0.0/15
      subnet: 10.0.0.0/16
      vswitch:
        vlan: 4000
        subnet: 10.1.0.0/24
  #{extra_vswitch}
  worker_node_pools:
  - name: robot
    instance_type: external
    instance_count: 1
    external:
      provider: robot
      robot_user: u
      robot_password: p
      nodes:
      - host: 1.2.3.4
        robot_server_number: 42
        private_ip: 10.1.0.2
        ssh_user: root
        ssh_private_key_path: /tmp/key
        index: 1
  YAML
  )
end

describe Cluster::VSwitchManager do
  it "creates the vswitch, attaches the server and waits for ready" do
    client = FakeRobotClient.new(statuses: ["in process", "ready"])
    id = Cluster::VSwitchManager.new(manager_settings, client, 0.seconds, 1.minute).ensure
    id.should eq(4321)
    client.calls[0, 3].should eq(["list", "create test 4000", "add 4321 42"])
    client.calls.count("get 4321").should eq(2)
  end

  it "re-run with everything in place makes only read calls" do
    client = FakeRobotClient.new([RVS.new(4321, "test", 4000, [RVSS.new(42, "ready")])])
    Cluster::VSwitchManager.new(manager_settings, client, 0.seconds, 1.minute).ensure.should eq(4321)
    client.calls.none? { |c| c.starts_with?("create") || c.starts_with?("add") }.should be_true
    client.calls.none? { |c| c.starts_with?("remove") || c.starts_with?("delete") }.should be_true
    client.calls.should eq(["list", "get 4321"])
  end

  it "uses existing_vswitch_id without listing" do
    client = FakeRobotClient.new([RVS.new(99, "other-name", 4000, [RVSS.new(42, "ready")])])
    Cluster::VSwitchManager.new(manager_settings("      existing_vswitch_id: 99"), client, 0.seconds, 1.minute).ensure.should eq(99)
    client.calls.should eq(["get 99"])
  end

  it "refuses a vlan mismatch" do
    client = FakeRobotClient.new([RVS.new(4321, "test", 4005, [] of RVSS)])
    expect_raises(Exception, /VLAN 4005/) { Cluster::VSwitchManager.new(manager_settings, client, 0.seconds, 1.minute).ensure }
  end

  it "waits for Robot to release the VLAN of a vSwitch cancelled moments ago" do
    client = FakeRobotClient.new([RVS.new(4321, "test", 4000, [] of RVSS)], ["in process", "ready"])
    client.vlan_busy_rejections = 2
    Cluster::VSwitchManager.new(manager_settings, client, 0.seconds, 1.minute, 1.minute).ensure.should eq(4321)
    client.calls.count { |c| c.starts_with?("add 4321 42") }.should eq(3)
  end

  it "gives up on a VLAN that stays in use past the release deadline" do
    client = FakeRobotClient.new([RVS.new(4321, "test", 4000, [] of RVSS)])
    client.vlan_busy_rejections = 1_000
    ex = expect_raises(Exception, /VLAN 4000 is still in use on Robot server\(s\) 42/) { Cluster::VSwitchManager.new(manager_settings, client, 0.seconds, 1.minute, 0.seconds).ensure }
    ex.message.not_nil!.should contain("VSWITCH_VLAN_NOT_UNIQUE")
  end

  it "aborts on a failed server status instead of waiting" do
    client = FakeRobotClient.new([RVS.new(4321, "test", 4000, [RVSS.new(42, "failed")])], ["failed"])
    expect_raises(Exception, /failed for server\(s\) 42/) { Cluster::VSwitchManager.new(manager_settings, client, 0.seconds, 1.minute).ensure }
  end

  it "refuses a server that is attached to a different vswitch" do
    client = FakeRobotClient.new([RVS.new(77, "other", 4005, [RVSS.new(42, "ready")])])
    expect_raises(Exception, /server\(s\) 42 .*already attached to vSwitch other \(77, VLAN 4005\)/) do
      Cluster::VSwitchManager.new(manager_settings, client, 0.seconds, 1.minute).ensure
    end
    client.calls.none?(&.starts_with?("create")).should be_true
  end

  it "returns nil without robot pools on the private network" do
    settings = Configuration::Main.from_yaml("hetzner_token: x\ncluster_name: t\nkubeconfig_path: /tmp/k\nk3s_version: v1.36.1+k3s1\nmasters_pool:\n  instance_type: cx22\n  instance_count: 1\n")
    Cluster::VSwitchManager.new(settings, FakeRobotClient.new, 0.seconds, 1.minute).ensure.should be_nil
  end

  it "cleanup detaches and deletes only an owned vswitch" do
    owned = FakeRobotClient.new([RVS.new(4321, "test", 4000, [RVSS.new(42, "ready")])])
    Cluster::VSwitchManager.new(manager_settings, owned, 0.seconds, 1.minute).cleanup
    owned.calls.should contain("remove 4321 42")
    owned.calls.should contain("delete 4321")

    foreign = FakeRobotClient.new([RVS.new(99, "theirs", 4000, [RVSS.new(42, "ready")])])
    Cluster::VSwitchManager.new(manager_settings("      existing_vswitch_id: 99"), foreign, 0.seconds, 1.minute).cleanup
    foreign.calls.should contain("remove 99 42")
    foreign.calls.should_not contain("delete 99")
  end

  it "cleanup detaches but keeps a vswitch with an explicit name" do
    client = FakeRobotClient.new([RVS.new(4321, "shared", 4000, [RVSS.new(42, "ready")])])
    Cluster::VSwitchManager.new(manager_settings("      name: shared"), client, 0.seconds, 1.minute).cleanup
    client.calls.should contain("remove 4321 42")
    client.calls.none?(&.starts_with?("delete")).should be_true
  end

  it "cleanup keeps an owned vswitch that still carries another server" do
    client = FakeRobotClient.new([RVS.new(4321, "test", 4000, [RVSS.new(42, "ready"), RVSS.new(77, "ready")])])
    Cluster::VSwitchManager.new(manager_settings, client, 0.seconds, 1.minute).cleanup
    client.calls.should contain("remove 4321 42")
    client.calls.none?(&.starts_with?("delete")).should be_true
  end

  it "cleanup treats a vswitch Robot no longer knows as already gone" do
    client = FakeRobotClient.new
    Cluster::VSwitchManager.new(manager_settings("      existing_vswitch_id: 99"), client, 0.seconds, 1.minute).cleanup
    client.calls.should eq(["get 99"])
  end

  it "cleanup still raises other Robot errors" do
    client = FailingRobotClient.new([RVS.new(99, "theirs", 4000, [RVSS.new(42, "ready")])])
    expect_raises(Hetzner::Robot::Client::Error, /UNAUTHORIZED/) do
      Cluster::VSwitchManager.new(manager_settings("      existing_vswitch_id: 99"), client, 0.seconds, 1.minute).cleanup
    end
  end

  it "ignores cancelled vswitches when looking up by name and scanning membership" do
    client = FakeRobotClient.new([RVS.new(1111, "test", 4000, [RVSS.new(42, "ready")], true)])
    Cluster::VSwitchManager.new(manager_settings, client, 0.seconds, 1.minute).ensure.should eq(4321)
    client.calls[0, 3].should eq(["list", "create test 4000", "add 4321 42"])
    client.calls.should_not contain("get 1111")
  end
end

class FailingRobotClient < FakeRobotClient
  def vswitch(id : Int32) : RVS
    calls << "get #{id}"
    raise Hetzner::Robot::Client::Error.new(%(Failed to fetch Robot vSwitch #{id}: {"error":{"status":401,"code":"UNAUTHORIZED","message":"Unauthorized"}}))
  end
end
