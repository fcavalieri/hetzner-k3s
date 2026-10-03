require "../spec_helper"
require "../../src/configuration/main"
require "../../src/kubernetes/worker/vlan_setup"
require "../../src/util/ssh"

ROBOT_CLUSTER = <<-YAML
hetzner_token: x
cluster_name: test
kubeconfig_path: /tmp/k
k3s_version: v1.36.1+k3s1
masters_pool:
  instance_type: cx22
  instance_count: 1
networking:
  private_network:
    ip_range: 10.0.0.0/15
    subnet: 10.0.0.0/16
    vswitch:
      vlan: 4000
      subnet: 10.1.0.0/24
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

# Runs a generated VLAN script under bash with its system paths moved into `dir` and the
# network tools replaced by stubs that log their calls. The VLAN address "exists" while the
# state file does: netplan apply and ifup create it, ifdown removes it.
def run_vlan_script(script : String, dir : String, env = {} of String => String) : {Int32, String, String}
  body = script
    .gsub(Kubernetes::Worker::VlanSetup::NETPLAN_PATH, "#{dir}/netplan.yaml")
    .gsub(Kubernetes::Worker::VlanSetup::INTERFACES_PATH, "#{dir}/vswitch")
    .gsub("/etc/network/interfaces.d", "#{dir}/interfaces.d")
    .gsub("/etc/network/interfaces", "#{dir}/interfaces")
  stubs = <<-SH
    LOG=#{dir}/calls.log
    STATE=#{dir}/up
    netplan() { echo "netplan $*" >> "$LOG"; case "$1" in generate) return ${GEN_RC:-0} ;; apply) touch "$STATE" ;; esac; }
    ifup() { echo "ifup $*" >> "$LOG"; [ "${IFUP_RC:-0}" = 0 ] || return "$IFUP_RC"; touch "$STATE"; }
    ifdown() { echo "ifdown $*" >> "$LOG"; rm -f "$STATE"; }
    dpkg() { return 0; }
    sleep() { :; }
    ip() {
      echo "ip $*" >> "$LOG"
      if [ "$*" = "-4 -o addr show dev vlan4000" ] && [ -e "$STATE" ]; then
        echo "5: vlan4000    inet 10.1.0.2/24 brd 10.1.0.255 scope global vlan4000"
      fi
    }
    SH
  File.write("#{dir}/calls.log", "")
  output = IO::Memory.new
  status = Process.run("bash", ["-c", stubs + "\n" + body], env: env, output: output, error: output)
  {status.exit_code, output.to_s, File.read("#{dir}/calls.log")}
end

def vlan_tmpdir : String
  dir = File.tempname("hk3s-vlan")
  Dir.mkdir(dir)
  dir
end

describe Kubernetes::Worker::VlanSetup do
  settings = Configuration::Main.from_yaml(ROBOT_CLUSTER)
  node = settings.robot_external_nodes.first
  setup = Kubernetes::Worker::VlanSetup.new(settings, node)

  it "names the interface vlan<id>, independent of the parent (IFNAMSIZ)" do
    setup.interface_name.should eq("vlan4000")
    Kubernetes::Worker::VlanSetup.interface_name_for(4091).should eq("vlan4091")
  end

  it "renders netplan per Hetzner's vSwitch guide" do
    yaml = setup.render("netplan", "enp5s0f0np0")
    yaml.should contain("    vlan4000:\n      id: 4000\n      link: enp5s0f0np0\n      mtu: 1400\n")
    yaml.should contain("        - 10.1.0.2/24\n")
    yaml.should contain("        - to: 10.0.0.0/15\n          via: 10.1.0.1\n")
  end

  it "renders ifupdown per Hetzner's vSwitch guide" do
    text = setup.render("ifupdown", "enp5s0f0np0")
    text.should contain("auto vlan4000\niface vlan4000 inet static\n  address 10.1.0.2\n  netmask 255.255.255.0\n  vlan-raw-device enp5s0f0np0\n  mtu 1400\n")
    text.should contain("up ip route add 10.0.0.0/15 via 10.1.0.1 dev vlan4000")
  end

  it "applies, pins the MTU and verifies the address" do
    cmd = setup.apply_command("netplan", "enp5s0f0np0")
    cmd.should contain("install -m 600 \"$TMP\" /etc/netplan/60-hetzner-k3s-vswitch.yaml")
    cmd.should contain("netplan apply")
    cmd.should contain("ip link set vlan4000 mtu 1400")
    cmd.should contain("grep -q ' 10.1.0.2/'")
    setup.apply_command("ifupdown", "enp5s0f0np0").should contain("ifup vlan4000")
    expect_raises(Exception, /unsupported/) { setup.apply_command("none", "enp5s0f0np0") }
  end

  it "guards both mechanisms with cmp -s and an unchanged branch" do
    {"netplan" => Kubernetes::Worker::VlanSetup::NETPLAN_PATH, "ifupdown" => Kubernetes::Worker::VlanSetup::INTERFACES_PATH}.each do |mechanism, path|
      cmd = setup.apply_command(mechanism, "enp5s0f0np0")
      cmd.should contain(%(if cmp -s "$TMP" #{path} && ip -4 -o addr show dev vlan4000 2>/dev/null | grep -q ' 10.1.0.2/'; then))
      cmd.should contain("  echo unchanged\n  exit 0\n")
    end
  end

  it "netplan: applies a new file, leaves an identical one alone, re-applies when the address is gone" do
    dir = vlan_tmpdir
    script = setup.apply_command("netplan", "enp5s0f0np0")

    status, _, log = run_vlan_script(script, dir)
    status.should eq(0)
    log.should contain("netplan generate\nnetplan apply\n")
    File.read("#{dir}/netplan.yaml").should eq(setup.render("netplan", "enp5s0f0np0"))

    status, output, log = run_vlan_script(script, dir)
    status.should eq(0)
    output.should contain("unchanged")
    log.should_not contain("netplan")

    File.delete("#{dir}/up")
    status, _, log = run_vlan_script(script, dir)
    status.should eq(0)
    log.should contain("netplan apply")
  end

  it "netplan: removes the file and fails when netplan generate rejects it" do
    dir = vlan_tmpdir
    status, output, log = run_vlan_script(setup.apply_command("netplan", "enp5s0f0np0"), dir, {"GEN_RC" => "1"})
    status.should_not eq(0)
    File.exists?("#{dir}/netplan.yaml").should be_false
    log.should_not contain("netplan apply")
    output.should contain("ERROR")
  end

  it "ifupdown: brings the interface up once, then reports unchanged" do
    dir = vlan_tmpdir
    script = setup.apply_command("ifupdown", "enp5s0f0np0")

    status, _, log = run_vlan_script(script, dir)
    status.should eq(0)
    log.should contain("ifup vlan4000")
    File.read("#{dir}/vswitch").should eq(setup.render("ifupdown", "enp5s0f0np0"))

    status, output, log = run_vlan_script(script, dir)
    status.should eq(0)
    output.should contain("unchanged")
    log.should_not contain("ifdown")
    log.should_not contain("ifup")
  end

  it "ifupdown: removes the file and fails when ifup fails" do
    dir = vlan_tmpdir
    status, output, _ = run_vlan_script(setup.apply_command("ifupdown", "enp5s0f0np0"), dir, {"IFUP_RC" => "1"})
    status.should_not eq(0)
    File.exists?("#{dir}/vswitch").should be_false
    output.should contain("ERROR")
  end

  it "recovers a dropped session by pinning the MTU and verifying the address" do
    cmd = setup.recovery_command
    cmd.should contain("ip link set vlan4000 mtu 1400")
    cmd.should contain("ip -4 -o addr show dev vlan4000 | grep -q ' 10.1.0.2/'")
  end

  it "treats only ssh's own exit status 255 as a dropped session" do
    Kubernetes::Worker::VlanSetup.session_dropped?(Util::SSH.failure_message("1.2.3.4", 255, "Connection closed")).should be_true
    Kubernetes::Worker::VlanSetup.session_dropped?(Util::SSH.failure_message("1.2.3.4", 1, "netplan: error")).should be_false
    Kubernetes::Worker::VlanSetup.session_dropped?(Util::SSH.failure_message("1.2.3.4", 25, "exit code: 2550")).should be_false
    Kubernetes::Worker::VlanSetup.session_dropped?("Instance has no IP address").should be_false
  end

  it "checks reachability of the master over the vSwitch" do
    setup.reachability_command("10.0.0.2").should eq("ping -c 2 -W 2 10.0.0.2 >/dev/null && timeout 5 bash -c '</dev/tcp/10.0.0.2/6443' 2>/dev/null")
  end

  it "retries the reachability check every interval, up to the attempt limit" do
    Kubernetes::Worker::VlanSetup::REACHABILITY_INTERVAL.should eq(10.seconds)
    (Kubernetes::Worker::VlanSetup::REACHABILITY_INTERVAL * (Kubernetes::Worker::VlanSetup::REACHABILITY_ATTEMPTS - 1)).should eq(120.seconds)

    calls = 0
    waits = [] of Int32
    result = Kubernetes::Worker::VlanSetup.with_retries(13, 0.seconds, ->(attempt : Int32) { waits << attempt; nil }) do
      calls += 1
      raise "unreachable" if calls < 3
      "ok"
    end
    result.should eq("ok")
    waits.should eq([1, 2])

    calls = 0
    expect_raises(Exception, /unreachable 3/) do
      Kubernetes::Worker::VlanSetup.with_retries(3, 0.seconds) do
        calls += 1
        raise "unreachable #{calls}"
      end
    end
    calls.should eq(3)
  end

  it "cleans up both files and exactly the VLAN link" do
    cmd = Kubernetes::Worker::VlanSetup.cleanup_command(4000)
    cmd.should contain("rm -f /etc/netplan/60-hetzner-k3s-vswitch.yaml /etc/network/interfaces.d/hetzner-k3s-vswitch")
    cmd.should contain("ip link del vlan4000 2>/dev/null || true")
    cmd.should_not contain("grep")
  end
end
