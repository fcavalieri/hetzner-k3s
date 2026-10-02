require "../spec_helper"
require "../support/loader"
require "../../src/kubernetes/software/cilium"

class RenderableCilium < Kubernetes::Software::Cilium
  def values : String
    generate_helm_values
  end
end

private def cilium_values(vswitch : Bool) : String
  vs = vswitch ? "    vswitch:\n      vlan: 4000\n      subnet: 10.1.0.0/24\n      mtu: 1400\n" : ""
  yaml = "hetzner_token: x\ncluster_name: test\nkubeconfig_path: /tmp/k\nk3s_version: v1.36.1+k3s1\nmasters_pool:\n  instance_type: cx22\n  instance_count: 1\nnetworking:\n  cni:\n    mode: cilium\n  private_network:\n    ip_range: 10.0.0.0/15\n    subnet: 10.0.0.0/16\n#{vs}"
  loader = loader_for(yaml)
  RenderableCilium.new(loader, loader.settings).values
end

describe "Cilium helm values" do
  it "carry the vSwitch MTU" do
    cilium_values(true).should contain("MTU: 1400")
  end

  it "have no MTU line without a vswitch" do
    cilium_values(false).should_not contain("MTU:")
  end
end
