require "../spec_helper"
require "../../src/configuration/main"
require "../../src/kubernetes/worker/vlan_setup"

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

describe Kubernetes::Worker::VlanSetup do
  settings = Configuration::Main.from_yaml(ROBOT_CLUSTER)
  node = settings.robot_external_nodes.first
  setup = Kubernetes::Worker::VlanSetup.new(settings, node)

  it "names the interface after the parent and the VLAN" do
    setup.interface_name("enp0s31f6").should eq("enp0s31f6.4000")
  end

  it "renders netplan per Hetzner's vSwitch guide" do
    yaml = setup.render("netplan", "enp0s31f6")
    yaml.should contain("    enp0s31f6.4000:\n      id: 4000\n      link: enp0s31f6\n      mtu: 1400\n")
    yaml.should contain("        - 10.1.0.2/24\n")
    yaml.should contain("        - to: 10.0.0.0/15\n          via: 10.1.0.1\n")
  end

  it "renders ifupdown per Hetzner's vSwitch guide" do
    text = setup.render("ifupdown", "enp0s31f6")
    text.should contain("iface enp0s31f6.4000 inet static\n  address 10.1.0.2\n  netmask 255.255.255.0\n  vlan-raw-device enp0s31f6\n  mtu 1400\n")
    text.should contain("up ip route add 10.0.0.0/15 via 10.1.0.1 dev enp0s31f6.4000")
  end

  it "applies, pins the MTU and verifies the address" do
    cmd = setup.apply_command("netplan", "enp0s31f6")
    cmd.should contain("base64 -d > /etc/netplan/60-hetzner-k3s-vswitch.yaml")
    cmd.should contain("netplan apply")
    cmd.should contain("ip link set enp0s31f6.4000 mtu 1400")
    cmd.should contain("grep -q ' 10.1.0.2/'")
    setup.apply_command("ifupdown", "enp0s31f6").should contain("ifup enp0s31f6.4000")
    expect_raises(Exception, /unsupported/) { setup.apply_command("none", "enp0s31f6") }
  end

  it "checks reachability of the master over the vSwitch" do
    setup.reachability_command("10.0.0.2").should eq("ping -c 2 -W 2 10.0.0.2 >/dev/null && timeout 5 bash -c '</dev/tcp/10.0.0.2/6443' 2>/dev/null")
  end

  it "cleans up both files and the VLAN link" do
    cmd = Kubernetes::Worker::VlanSetup.cleanup_command(4000)
    cmd.should contain("rm -f /etc/netplan/60-hetzner-k3s-vswitch.yaml /etc/network/interfaces.d/hetzner-k3s-vswitch")
    cmd.should contain(%(grep "\\.4000$"))
  end
end
