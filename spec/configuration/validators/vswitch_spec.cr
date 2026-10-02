require "../../spec_helper"
require "../../../src/configuration/main"
require "../../../src/configuration/validators/networking_config/vswitch"

BASE = <<-YAML
hetzner_token: x
cluster_name: test
kubeconfig_path: /tmp/kubeconfig
k3s_version: v1.36.1+k3s1
masters_pool:
  instance_type: cx22
  instance_count: 1
  locations: [%LOC%]
YAML

ROBOT_POOL = <<-YAML
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

def vswitch_errors(networking_yaml : String, location = "fsn1", pools = "") : Array(String)
  yaml = BASE.sub("%LOC%", location) + "\n" + pools + "\n" + networking_yaml
  settings = Configuration::Main.from_yaml(yaml)
  errors = [] of String
  Configuration::Validators::NetworkingConfig::VSwitch.new(errors, settings.networking.private_network, settings).validate
  errors
end

GOOD = <<-YAML
networking:
  private_network:
    ip_range: 10.0.0.0/15
    subnet: 10.0.0.0/16
    vswitch:
      vlan: 4000
      subnet: 10.1.0.0/24
YAML

describe Configuration::Validators::NetworkingConfig::VSwitch do
  it "accepts a well-formed layout" do
    vswitch_errors(GOOD).should be_empty
  end

  it "is silent without the new keys and without robot pools" do
    vswitch_errors("networking: {}").should be_empty
  end

  it "requires vswitch when a robot pool uses the private network" do
    errors = vswitch_errors("networking: {}", pools: ROBOT_POOL)
    errors.any?(&.includes?("vswitch is required")).should be_true
  end

  it "requires ip_range to contain subnet" do
    errors = vswitch_errors(GOOD.sub("ip_range: 10.0.0.0/15", "ip_range: 10.2.0.0/16"))
    errors.any?(&.includes?("must contain subnet")).should be_true
  end

  it "rejects a vswitch subnet outside ip_range" do
    errors = vswitch_errors(GOOD.sub("subnet: 10.1.0.0/24", "subnet: 10.9.0.0/24"))
    errors.any?(&.includes?("inside the private network ip_range")).should be_true
  end

  it "rejects a vswitch subnet overlapping the cloud subnet" do
    errors = vswitch_errors(GOOD.sub("subnet: 10.1.0.0/24", "subnet: 10.0.5.0/24"))
    errors.any?(&.includes?("must not overlap the cloud subnet")).should be_true
  end

  it "rejects a vswitch subnet containing the network gateway" do
    errors = vswitch_errors(GOOD.sub("ip_range: 10.0.0.0/15", "ip_range: 10.0.0.0/8").sub("subnet: 10.1.0.0/24", "subnet: 10.0.0.0/24").sub("subnet: 10.0.0.0/16\n", "subnet: 10.5.0.0/16\n"))
    errors.any?(&.includes?("first address")).should be_true
  end

  it "rejects vlan and mtu out of range" do
    errors = vswitch_errors(GOOD.sub("vlan: 4000", "vlan: 3999") + "\n" + "      mtu: 1500\n")
    errors.any?(&.includes?("vlan must be between 4000 and 4091")).should be_true
    errors.any?(&.includes?("mtu must be between 1280 and 1400")).should be_true
  end

  it "rejects non eu-central masters" do
    errors = vswitch_errors(GOOD, location: "ash")
    errors.any?(&.includes?("eu-central")).should be_true
  end

  it "rejects Cilium native routing with robot nodes on the private network" do
    errors = vswitch_errors(GOOD + "\n" + "  cni:\n    mode: cilium\n    cilium:\n      routing_mode: native\n", pools: ROBOT_POOL)
    errors.any?(&.includes?("native routing")).should be_true
  end
end
