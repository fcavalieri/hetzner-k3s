require "../spec_helper"
require "../support/k3s_stubs"
require "../support/loader"
require "../../src/kubernetes/script/master_generator"
require "../../src/kubernetes/script/worker_generator"
require "../../src/kubernetes/kubeconfig_manager"

BASE_CLUSTER = "hetzner_token: x\ncluster_name: test\nkubeconfig_path: /tmp/k\nk3s_version: v1.36.1+k3s1\nmasters_pool:\n  instance_type: cx22\n  instance_count: 1\nworker_node_pools:\n- name: static\n  instance_type: cx22\n  instance_count: 1\n"
VSWITCH_NET = "networking:\n  cni:\n    encryption: false\n  private_network:\n    ip_range: 10.0.0.0/15\n    subnet: 10.0.0.0/16\n    vswitch:\n      vlan: 4000\n      subnet: 10.1.0.0/24\n"

describe "install scripts" do
  K3s.preset_token("spec-token")
  master = Hetzner::Instance.new(1, "running", "test-master1", "10.0.0.2", "1.1.1.1")

  it "pass --flannel-conf on master and worker when a vswitch is configured" do
    loader = loader_for(BASE_CLUSTER + VSWITCH_NET)
    settings = loader.settings
    kubeconfig_manager = Kubernetes::KubeconfigManager.new(loader, settings, Util::SSH.new("/tmp/key"))
    master_script = Kubernetes::Script::MasterGenerator.new(loader, settings).generate_script(master, [master], master, nil, kubeconfig_manager)
    master_script.should contain("cat >/etc/rancher/k3s/flannel-net-conf.json")
    master_script.should contain(%("Type": "vxlan", "MTU": 1400))
    master_script.should contain("--flannel-conf=/etc/rancher/k3s/flannel-net-conf.json")
    worker_script = Kubernetes::Script::WorkerGenerator.new(loader, settings).generate_script([master], master, settings.worker_node_pools.first)
    worker_script.should contain("--flannel-conf=/etc/rancher/k3s/flannel-net-conf.json")
    worker_script.should contain(%("MTU": 1400))
  end

  it "pass the wireguard backend and MTU when encryption is on" do
    net = VSWITCH_NET.sub("encryption: false", "mode: flannel\n    encryption: true")
    loader = loader_for(BASE_CLUSTER + net)
    settings = loader.settings
    kubeconfig_manager = Kubernetes::KubeconfigManager.new(loader, settings, Util::SSH.new("/tmp/key"))
    master_script = Kubernetes::Script::MasterGenerator.new(loader, settings).generate_script(master, [master], master, nil, kubeconfig_manager)
    worker_script = Kubernetes::Script::WorkerGenerator.new(loader, settings).generate_script([master], master, settings.worker_node_pools.first)
    master_script.should contain("--flannel-backend=wireguard-native")
    [master_script, worker_script].each do |script|
      script.should contain(%("Type": "wireguard", "PersistentKeepaliveInterval": 25, "MTU": 1400))
      script.should contain("--flannel-conf=/etc/rancher/k3s/flannel-net-conf.json")
    end
  end

  it "render no flannel override without a vswitch" do
    loader = loader_for(BASE_CLUSTER + "networking:\n  cni:\n    encryption: false\n")
    settings = loader.settings
    kubeconfig_manager = Kubernetes::KubeconfigManager.new(loader, settings, Util::SSH.new("/tmp/key"))
    Kubernetes::Script::MasterGenerator.new(loader, settings).generate_script(master, [master], master, nil, kubeconfig_manager).should_not contain("flannel-conf")
    Kubernetes::Script::WorkerGenerator.new(loader, settings).generate_script([master], master, settings.worker_node_pools.first).should_not contain("flannel-conf")
  end

  it "uses the injected private IP and VLAN interface for a Robot node" do
    robot_yaml = BASE_CLUSTER + "- name: robot\n  instance_type: external\n  instance_count: 1\n  external:\n    provider: robot\n    robot_user: u\n    robot_password: p\n    nodes:\n    - host: 1.2.3.4\n      robot_server_number: 42\n      private_ip: 10.1.0.2\n      ssh_user: root\n      ssh_private_key_path: /tmp/key\n      index: 1\n" + VSWITCH_NET
    loader = loader_for(robot_yaml)
    settings = loader.settings
    pool = settings.worker_node_pools.last
    script = Kubernetes::Script::WorkerGenerator.new(loader, settings).generate_script([master], master, pool, pool.external.not_nil!.nodes.first, "enp0s31f6.4000")
    script.should contain(%(NETWORK_INTERFACE="enp0s31f6.4000"))
    script.should contain(%(PRIVATE_IP="10.1.0.2"))
    script.should contain("K3S_URL=https://10.0.0.2:6443")
    script.should contain("--flannel-iface=$NETWORK_INTERFACE")
    script.should contain("provider-id=hrobot://42")
  end

  it "keeps interface detection for cloud workers on the private network" do
    loader = loader_for(BASE_CLUSTER + VSWITCH_NET)
    settings = loader.settings
    script = Kubernetes::Script::WorkerGenerator.new(loader, settings).generate_script([master], master, settings.worker_node_pools.first)
    script.should contain("Waiting for private network interface")
    script.should contain(%(if [ -n "" ]; then))
  end
end
