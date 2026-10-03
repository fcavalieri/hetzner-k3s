require "../spec_helper"
require "../../src/configuration/main"
require "../../src/hetzner/firewall/create"

class FirewallRecordingClient < Hetzner::Client
  getter bodies = [] of String

  def initialize
    super("token")
  end

  def get(path, params : Hash = {} of Symbol => String | Bool | Nil)
    {true, bodies.empty? ? %({"firewalls":[]}) : %({"firewalls":[{"id":7,"name":"test"}]})}
  end

  def post(path, params)
    bodies << params.to_json
    {true, %({"firewall":{"id":7,"name":"test"}})}
  end
end

describe Hetzner::Firewall::Create do
  it "allows node-to-node traffic from the whole network range" do
    settings = Configuration::Main.from_yaml("hetzner_token: x\ncluster_name: test\nkubeconfig_path: /tmp/k\nk3s_version: v1.36.1+k3s1\nmasters_pool:\n  instance_type: cx22\n  instance_count: 1\nnetworking:\n  private_network:\n    ip_range: 10.0.0.0/15\n    subnet: 10.0.0.0/16\n")
    client = FirewallRecordingClient.new
    Hetzner::Firewall::Create.new(settings, client, "test", [] of Hetzner::Instance).run
    body = client.bodies.first
    body.scan(/"description":"Allow all (TCP|UDP) traffic between nodes on the private network","direction":"in","protocol":"(tcp|udp)","port":"any","source_ips":\["10.0.0.0\/15"\]/).size.should eq(2)
    body.includes?(%("source_ips":["10.0.0.0/16"])).should be_false
  end

  it "keeps using the subnet when no ip_range is configured" do
    settings = Configuration::Main.from_yaml("hetzner_token: x\ncluster_name: test\nkubeconfig_path: /tmp/k\nk3s_version: v1.36.1+k3s1\nmasters_pool:\n  instance_type: cx22\n  instance_count: 1\n")
    client = FirewallRecordingClient.new
    Hetzner::Firewall::Create.new(settings, client, "test", [] of Hetzner::Instance).run
    client.bodies.first.scan(%("source_ips":["10.0.0.0/16"])).size.should eq(2)
  end
end
