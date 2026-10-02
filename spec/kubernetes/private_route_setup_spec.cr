require "../spec_helper"
require "../../src/configuration/main"
require "../../src/util/ssh"
require "../../src/kubernetes/network/private_route_setup"

def route_settings(networking : String) : Configuration::Main
  Configuration::Main.from_yaml("hetzner_token: x\ncluster_name: test\nkubeconfig_path: /tmp/k\nk3s_version: v1.36.1+k3s1\nmasters_pool:\n  instance_type: cx22\n  instance_count: 1\n" + networking)
end

describe Kubernetes::Network::PrivateRouteSetup do
  it "replaces the route on the interface that reaches the gateway" do
    cmd = Kubernetes::Network::PrivateRouteSetup.command("10.0.0.0/15", "10.0.0.1")
    cmd.should contain("ip -o -4 route get 10.0.0.1")
    cmd.should contain(%(ip route replace 10.0.0.0/15 via 10.0.0.1 dev "$IFACE"))
  end

  it "is needed only when the range was widened or a vswitch exists" do
    ssh = Util::SSH.new("/tmp/key")
    Kubernetes::Network::PrivateRouteSetup.new(route_settings(""), ssh).needed?.should be_false
    Kubernetes::Network::PrivateRouteSetup.new(route_settings("networking:\n  private_network:\n    ip_range: 10.0.0.0/15\n"), ssh).needed?.should be_true
    Kubernetes::Network::PrivateRouteSetup.new(route_settings("networking:\n  private_network:\n    enabled: false\n    ip_range: 10.0.0.0/15\n"), ssh).needed?.should be_false
  end
end
