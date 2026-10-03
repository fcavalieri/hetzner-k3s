require "../../spec_helper"
require "../../../src/configuration/main"
require "../../../src/configuration/validators/external_node_pool"

HEAD = <<-YAML
hetzner_token: x
cluster_name: test
kubeconfig_path: /tmp/kubeconfig
k3s_version: v1.36.1+k3s1
masters_pool:
  instance_type: cx22
  instance_count: 1
  locations: [fsn1]
YAML

PRIVATE_WITH_VSWITCH = <<-YAML
networking:
  private_network:
    enabled: true
    ip_range: 10.0.0.0/15
    subnet: 10.0.0.0/16
    vswitch:
      vlan: 4000
      subnet: 10.1.0.0/24
YAML

def pool_yaml(provider : String, private_ip : String?, extra_node = "", parent : String? = nil) : String
  ip_line = private_ip ? "      private_ip: #{private_ip}\n" : ""
  parent_line = parent ? "      vlan_parent_interface: \"#{parent}\"\n" : ""
  <<-YAML
  worker_node_pools:
  - name: ext
    instance_type: external
    instance_count: #{extra_node.empty? ? 1 : 2}
    external:
      provider: #{provider}
      robot_user: u
      robot_password: p
      nodes:
      - host: 1.2.3.4
        robot_server_number: 42
  #{ip_line}#{parent_line}      ssh_user: root
        ssh_private_key_path: /tmp/key
        index: 1
  #{extra_node}
  YAML
end

def pool_errors(networking : String, pools : String) : Array(String)
  settings = Configuration::Main.from_yaml(HEAD + "\n" + networking + "\n" + pools)
  errors = [] of String
  settings.worker_node_pools.each do |pool|
    Configuration::Validators::ExternalNodePool.new(errors, pool, settings).validate
  end
  errors
end

describe Configuration::Validators::ExternalNodePool do
  it "accepts a robot pool with a private IP in the vswitch subnet" do
    pool_errors(PRIVATE_WITH_VSWITCH, pool_yaml("robot", "10.1.0.2")).should be_empty
  end

  it "still rejects a generic pool on the private network" do
    errors = pool_errors(PRIVATE_WITH_VSWITCH, pool_yaml("generic", nil))
    errors.any?(&.includes?("only Robot pools can join the private network")).should be_true
  end

  it "rejects a robot pool on the private network without a vswitch block" do
    errors = pool_errors("networking:\n  private_network:\n    enabled: true\n", pool_yaml("robot", "10.1.0.2"))
    errors.any?(&.includes?("vswitch must be configured")).should be_true
  end

  it "requires private_ip for robot nodes on the private network" do
    errors = pool_errors(PRIVATE_WITH_VSWITCH, pool_yaml("robot", nil))
    errors.any?(&.includes?("missing private_ip")).should be_true
  end

  it "rejects a private_ip outside the vswitch subnet" do
    errors = pool_errors(PRIVATE_WITH_VSWITCH, pool_yaml("robot", "10.0.0.9"))
    errors.any?(&.includes?("outside the vswitch subnet")).should be_true
  end

  it "rejects the vswitch gateway as private_ip" do
    errors = pool_errors(PRIVATE_WITH_VSWITCH, pool_yaml("robot", "10.1.0.1"))
    errors.any?(&.includes?("gateway")).should be_true
  end

  it "rejects an IPv6 or malformed private_ip as outside the vswitch subnet" do
    ["fd00::2", "abc"].each do |bad|
      errors = pool_errors(PRIVATE_WITH_VSWITCH, pool_yaml("robot", bad))
      errors.any?(&.includes?("private_ip #{bad} outside the vswitch subnet")).should be_true
    end
  end

  it "rejects the vswitch subnet's network and broadcast addresses as private_ip" do
    pool_errors(PRIVATE_WITH_VSWITCH, pool_yaml("robot", "10.1.0.0")).any?(&.includes?("private_ip 10.1.0.0, which is the vswitch subnet's network address")).should be_true
    pool_errors(PRIVATE_WITH_VSWITCH, pool_yaml("robot", "10.1.0.255")).any?(&.includes?("private_ip 10.1.0.255, which is the vswitch subnet's broadcast address")).should be_true
    pool_errors(PRIVATE_WITH_VSWITCH, pool_yaml("robot", "10.1.0.254")).should be_empty
  end

  it "accepts a Linux interface name as vlan_parent_interface" do
    ["enp5s0f0np0", "eth0", "bond0.100", "abcdefghijklmno"].each do |name|
      pool_errors(PRIVATE_WITH_VSWITCH, pool_yaml("robot", "10.1.0.2", parent: name)).should be_empty
    end
  end

  it "rejects a vlan_parent_interface that is not a Linux interface name" do
    ["enp5s0f0np0.4000", "eth0; reboot", "eth 0", "abcdefghijklmnop"].each do |name|
      errors = pool_errors(PRIVATE_WITH_VSWITCH, pool_yaml("robot", "10.1.0.2", parent: name))
      errors.any?(&.includes?("vlan_parent_interface '#{name}'")).should be_true
    end
  end

  it "rejects duplicate private_ips" do
    second = "    - host: 5.6.7.8\n      robot_server_number: 43\n      private_ip: 10.1.0.2\n      ssh_user: root\n      ssh_private_key_path: /tmp/key\n      index: 2"
    errors = pool_errors(PRIVATE_WITH_VSWITCH, pool_yaml("robot", "10.1.0.2", second))
    errors.any?(&.includes?("duplicate private_ip")).should be_true
  end

  it "does not require the local firewall on the private network" do
    pool_errors(PRIVATE_WITH_VSWITCH, pool_yaml("robot", "10.1.0.2")).none?(&.includes?("local firewall")).should be_true
  end

  it "keeps the public-network rules unchanged" do
    public_net = "networking:\n  private_network:\n    enabled: false\n  public_network:\n    use_local_firewall: false\n"
    errors = pool_errors(public_net, pool_yaml("generic", nil))
    errors.any?(&.includes?("requires the local firewall")).should be_true
  end
end
