require "../spec_helper"
require "../../src/configuration/main"
require "../../src/kubernetes/script/flannel_conf"

def mtu_settings(cni : String, encryption : Bool, vswitch : Bool) : Configuration::Main
  vs = vswitch ? "    vswitch:\n      vlan: 4000\n      subnet: 10.1.0.0/24\n      mtu: 1400\n" : ""
  Configuration::Main.from_yaml("hetzner_token: x\ncluster_name: test\nkubeconfig_path: /tmp/k\nk3s_version: v1.36.1+k3s1\nmasters_pool:\n  instance_type: cx22\n  instance_count: 1\nnetworking:\n  cni:\n    mode: #{cni}\n    encryption: #{encryption}\n  private_network:\n    ip_range: 10.0.0.0/15\n    subnet: 10.0.0.0/16\n#{vs}")
end

describe Kubernetes::Script::FlannelConf do
  it "renders a vxlan config carrying the vSwitch MTU" do
    conf = Kubernetes::Script::FlannelConf.render(mtu_settings("flannel", false, true))
    conf.should contain(%("Network": "10.244.0.0/16"))
    conf.should contain(%("Type": "vxlan", "MTU": 1400))
    conf.should contain(%("EnableIPv6": false))
  end

  it "renders a wireguard config when encryption is on" do
    conf = Kubernetes::Script::FlannelConf.render(mtu_settings("flannel", true, true))
    conf.should contain(%("Type": "wireguard", "PersistentKeepaliveInterval": 25, "MTU": 1400))
  end

  it "renders nothing without a vswitch or with Cilium" do
    Kubernetes::Script::FlannelConf.render(mtu_settings("flannel", false, false)).should eq("")
    Kubernetes::Script::FlannelConf.render(mtu_settings("cilium", true, true)).should eq("")
    Kubernetes::NetworkMTU.for(mtu_settings("cilium", true, true)).should eq(1400)
    Kubernetes::NetworkMTU.for(mtu_settings("flannel", false, false)).should be_nil
  end

  it "assumes no MTU when the private network is disabled" do
    settings = Configuration::Main.from_yaml(mtu_settings_yaml_disabled)
    Kubernetes::NetworkMTU.for(settings).should be_nil
    Kubernetes::Script::FlannelConf.render(settings).should eq("")
  end

  it "reports the flannel.1 MTU flannel derives from the backend MTU, only for VXLAN" do
    Kubernetes::Script::FlannelConf.vxlan_device_mtu(mtu_settings("flannel", false, true)).should eq("1350")
    Kubernetes::Script::FlannelConf.vxlan_device_mtu(mtu_settings("flannel", true, true)).should eq("")
    Kubernetes::Script::FlannelConf.vxlan_device_mtu(mtu_settings("flannel", false, false)).should eq("")
    Kubernetes::Script::FlannelConf.vxlan_device_mtu(mtu_settings("cilium", false, true)).should eq("")
  end
end

def mtu_settings_yaml_disabled : String
  "hetzner_token: x\ncluster_name: test\nkubeconfig_path: /tmp/k\nk3s_version: v1.36.1+k3s1\nmasters_pool:\n  instance_type: cx22\n  instance_count: 1\nnetworking:\n  private_network:\n    enabled: false\n    ip_range: 10.0.0.0/15\n    subnet: 10.0.0.0/16\n    vswitch:\n      vlan: 4000\n      subnet: 10.1.0.0/24\n"
end
