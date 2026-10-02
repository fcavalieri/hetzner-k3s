require "../spec_helper"
require "../../src/configuration/main"

MINIMAL_YAML = <<-YAML
hetzner_token: x
cluster_name: test
kubeconfig_path: /tmp/kubeconfig
k3s_version: v1.36.1+k3s1
masters_pool:
  instance_type: cx22
  instance_count: 1
  locations: [fsn1]
YAML

describe Configuration::Models::NetworkingConfig::VSwitch do
  it "parses with defaults" do
    settings = Configuration::Main.from_yaml(MINIMAL_YAML + "\n" + <<-YAML
    networking:
      private_network:
        ip_range: 10.0.0.0/15
        subnet: 10.0.0.0/16
        vswitch:
          vlan: 4000
          subnet: 10.1.0.0/24
    YAML
    )
    pn = settings.networking.private_network
    pn.effective_ip_range.should eq("10.0.0.0/15")
    pn.gateway.should eq("10.0.0.1")
    vs = pn.vswitch.not_nil!
    vs.mtu.should eq(1400)
    vs.name_for("test").should eq("test")
    vs.gateway.should eq("10.1.0.1")
    vs.prefix.should eq(24)
    vs.netmask.should eq("255.255.255.0")
    vs.contains?("10.1.0.2").should be_true
    vs.contains?("10.0.0.2").should be_false
    vs.contains?("fd00::2").should be_false
    vs.contains?("abc").should be_false
    vs.network_address.should eq("10.1.0.0")
    vs.broadcast_address.should eq("10.1.0.255")
  end

  it "answers contains? without raising when the vswitch subnet itself is invalid" do
    Configuration::Models::NetworkingConfig::VSwitch.new(4000, "fd00::/64").contains?("10.1.0.2").should be_false
    Configuration::Models::NetworkingConfig::VSwitch.new(4000, "garbage").contains?("10.1.0.2").should be_false
  end

  it "keeps today's behaviour without the new keys" do
    settings = Configuration::Main.from_yaml(MINIMAL_YAML)
    pn = settings.networking.private_network
    pn.ip_range.should be_nil
    pn.effective_ip_range.should eq("10.0.0.0/16")
    pn.vswitch.should be_nil
    settings.robot_private_network?.should be_false
    settings.robot_external_nodes.should be_empty
  end

  it "exposes robot nodes with private IPs" do
    settings = Configuration::Main.from_yaml(MINIMAL_YAML + "\n" + <<-YAML
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
          vlan_parent_interface: enp0s31f6
          ssh_user: root
          ssh_private_key_path: /tmp/key
          index: 1
    YAML
    )
    settings.robot_private_network?.should be_true
    node = settings.robot_external_nodes.first
    node.private_ip.should eq("10.1.0.2")
    node.vlan_parent_interface.should eq("enp0s31f6")
  end
end
