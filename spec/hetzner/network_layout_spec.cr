require "../spec_helper"
require "../../src/configuration/main"
require "../../src/hetzner/network/create"
require "../../src/hetzner/network/ensure_layout"
require "../../src/hetzner/network/delete_subnet"

# In-memory Hetzner API: one network, mutated by the actions it receives.
class FakeHetznerClient < Hetzner::Client
  getter calls = [] of String
  property network_json : String?   # nil = no network yet

  def initialize(@network_json = nil)
    super("token")
  end

  def get(path, params : Hash = {} of Symbol => String | Bool | Nil)
    calls << "GET #{path}"
    {true, %({"networks":[#{network_json || ""}]})}
  end

  def post(path, params)
    calls << "POST #{path} #{params.to_json}"
    body = JSON.parse(params.to_json)
    case path
    when "/networks"
      self.network_json = %({"id":1,"name":"test","ip_range":"#{body["ip_range"].as_s}","subnets":[{"type":"cloud","ip_range":"#{body["subnets"][0]["ip_range"].as_s}","network_zone":"eu-central","gateway":"10.0.0.1"}],"servers":[]})
    when "/networks/1/actions/change_ip_range"
      self.network_json = network_json.not_nil!.sub(/"ip_range":"[^"]+"/, %("ip_range":"#{body["ip_range"].as_s}"))
    when "/networks/1/actions/add_subnet"
      self.network_json = network_json.not_nil!.sub(%("subnets":[), %("subnets":[{"type":"vswitch","ip_range":"#{body["ip_range"].as_s}","network_zone":"eu-central","gateway":"10.1.0.1","vswitch_id":#{body["vswitch_id"].as_i}},))
    when "/networks/1/actions/delete_subnet"
      self.network_json = network_json.not_nil!.sub(/\{"type":"[a-z]+","ip_range":"#{Regex.escape(body["ip_range"].as_s)}"[^}]*\},?/, "")
    end
    {true, %({"action":{"id":1,"status":"success"}})}
  end
end

# ip_range nil leaves the key out (a configuration without the new keys).
def layout_settings(ip_range : String? = "10.0.0.0/15", vswitch = true) : Configuration::Main
  vs = vswitch ? "    vswitch:\n      vlan: 4000\n      subnet: 10.1.0.0/24\n" : ""
  range = ip_range ? "    ip_range: #{ip_range}\n" : ""
  Configuration::Main.from_yaml("hetzner_token: x\ncluster_name: test\nkubeconfig_path: /tmp/k\nk3s_version: v1.36.1+k3s1\nmasters_pool:\n  instance_type: cx22\n  instance_count: 1\nnetworking:\n  private_network:\n#{range}    subnet: 10.0.0.0/16\n#{vs}")
end

LIVE_8 = %({"id":1,"name":"test","ip_range":"10.0.0.0/8","subnets":[{"type":"cloud","ip_range":"10.0.0.0/16","network_zone":"eu-central","gateway":"10.0.0.1"}],"servers":[]})
LIVE_16 = %({"id":1,"name":"test","ip_range":"10.0.0.0/16","subnets":[{"type":"cloud","ip_range":"10.0.0.0/16","network_zone":"eu-central","gateway":"10.0.0.1"}],"servers":[]})

def network_of(client) : Hetzner::Network
  Hetzner::Network::Find.new(client, "test").run.not_nil!
end

describe Hetzner::Network::Create do
  it "creates the network with ip_range wider than the cloud subnet" do
    client = FakeHetznerClient.new
    Hetzner::Network::Create.new(layout_settings, client, "test", "eu-central").run
    client.calls.any? { |c| c.starts_with?("POST /networks ") && c.includes?(%("ip_range":"10.0.0.0/15")) && c.includes?(%("subnets":[{"ip_range":"10.0.0.0/16")) }.should be_true
  end
end

describe Hetzner::Network::EnsureLayout do
  it "is not needed without the new keys" do
    Hetzner::Network::EnsureLayout.needed?(layout_settings(nil, vswitch: false)).should be_false
    Hetzner::Network::EnsureLayout.needed?(layout_settings(vswitch: false)).should be_true
    Hetzner::Network::EnsureLayout.needed?(layout_settings(nil)).should be_true
  end

  it "leaves an existing wider network untouched without the new keys" do
    client = FakeHetznerClient.new(LIVE_8)
    network = Hetzner::Network::EnsureLayout.new(layout_settings(nil, vswitch: false), client, network_of(client), "eu-central", nil).run
    client.calls.none?(&.starts_with?("POST")).should be_true
    network.ip_range.should eq("10.0.0.0/8")
  end

  it "does nothing when the layout already matches" do
    client = FakeHetznerClient.new(LIVE_16.sub("10.0.0.0/16\",\"subnets", "10.0.0.0/15\",\"subnets").sub(%("subnets":[), %("subnets":[{"type":"vswitch","ip_range":"10.1.0.0/24","network_zone":"eu-central","gateway":"10.1.0.1","vswitch_id":4321},)))
    Hetzner::Network::EnsureLayout.new(layout_settings, client, network_of(client), "eu-central", 4321).run
    client.calls.none?(&.starts_with?("POST")).should be_true
  end

  it "extends a narrower live range in place" do
    client = FakeHetznerClient.new(LIVE_16)
    network = Hetzner::Network::EnsureLayout.new(layout_settings(vswitch: false), client, network_of(client), "eu-central", nil).run
    client.calls.should contain(%(POST /networks/1/actions/change_ip_range {"ip_range":"10.0.0.0/15"}))
    network.ip_range.should eq("10.0.0.0/15")
  end

  it "refuses a configured range that does not contain the live one" do
    client = FakeHetznerClient.new(LIVE_16)
    expect_raises(Exception, /does not contain/) do
      Hetzner::Network::EnsureLayout.new(layout_settings("10.2.0.0/16", vswitch: false), client, network_of(client), "eu-central", nil).run
    end
    client.calls.none?(&.starts_with?("POST")).should be_true
  end

  it "adds the vswitch subnet when missing" do
    client = FakeHetznerClient.new(LIVE_16)
    network = Hetzner::Network::EnsureLayout.new(layout_settings, client, network_of(client), "eu-central", 4321).run
    client.calls.should contain(%(POST /networks/1/actions/add_subnet {"type":"vswitch","ip_range":"10.1.0.0/24","network_zone":"eu-central","vswitch_id":4321}))
    network.vswitch_subnet.not_nil!.vswitch_id.should eq(4321_i64)
  end

  it "refuses an existing vswitch subnet with another id or range" do
    client = FakeHetznerClient.new(LIVE_16.sub("10.0.0.0/16\",\"subnets", "10.0.0.0/15\",\"subnets").sub(%("subnets":[), %("subnets":[{"type":"vswitch","ip_range":"10.1.0.0/24","network_zone":"eu-central","gateway":"10.1.0.1","vswitch_id":9999},)))
    expect_raises(Exception, /already has a vSwitch subnet/) do
      Hetzner::Network::EnsureLayout.new(layout_settings, client, network_of(client), "eu-central", 4321).run
    end
    client.calls.none?(&.starts_with?("POST")).should be_true
  end

  it "refuses an existing vswitch subnet with the same id but another range" do
    client = FakeHetznerClient.new(LIVE_16.sub("10.0.0.0/16\",\"subnets", "10.0.0.0/15\",\"subnets").sub(%("subnets":[), %("subnets":[{"type":"vswitch","ip_range":"10.1.1.0/24","network_zone":"eu-central","gateway":"10.1.1.1","vswitch_id":4321},)))
    expect_raises(Exception, /already has a vSwitch subnet 10.1.1.0\/24 \(vSwitch 4321\) but the configuration says 10.1.0.0\/24/) do
      Hetzner::Network::EnsureLayout.new(layout_settings, client, network_of(client), "eu-central", 4321).run
    end
    client.calls.none?(&.starts_with?("POST")).should be_true
  end
end

LIVE_WITH_VSWITCH = LIVE_16.sub("10.0.0.0/16\",\"subnets", "10.0.0.0/15\",\"subnets").sub(%("subnets":[), %("subnets":[{"type":"vswitch","ip_range":"10.1.0.0/24","network_zone":"eu-central","gateway":"10.1.0.1","vswitch_id":4321},))

describe Hetzner::Network::DeleteSubnet do
  it "removes the vSwitch subnet from a network that survives delete" do
    client = FakeHetznerClient.new(LIVE_WITH_VSWITCH)
    Hetzner::Network::DeleteSubnet.new(client, network_of(client), "10.1.0.0/24").run.should be_true
    client.calls.should contain(%(POST /networks/1/actions/delete_subnet {"ip_range":"10.1.0.0/24"}))
    remaining = network_of(client)
    remaining.vswitch_subnet.should be_nil
    remaining.cloud_subnet.not_nil!.ip_range.should eq("10.0.0.0/16")
  end

  it "leaves a network without a vSwitch subnet of that range alone" do
    client = FakeHetznerClient.new(LIVE_16)
    Hetzner::Network::DeleteSubnet.new(client, network_of(client), "10.1.0.0/24").run.should be_false
    client = FakeHetznerClient.new(LIVE_WITH_VSWITCH)
    Hetzner::Network::DeleteSubnet.new(client, network_of(client), "10.1.1.0/24").run.should be_false
    client.calls.none?(&.starts_with?("POST")).should be_true
  end
end
