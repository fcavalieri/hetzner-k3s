require "../spec_helper"
require "../../src/hetzner/networks_list"

NETWORK_JSON = <<-JSON
{"networks":[{"id":11898291,"name":"reportix","ip_range":"10.0.0.0/16",
 "subnets":[{"type":"cloud","ip_range":"10.0.0.0/16","network_zone":"eu-central","gateway":"10.0.0.1"},
            {"type":"vswitch","ip_range":"10.1.0.0/24","network_zone":"eu-central","gateway":"10.1.0.1","vswitch_id":4321}],
 "routes":[],"servers":[119727691,119727720],"protection":{"delete":false},"labels":{},"created":"2026-01-01T00:00:00+00:00"}]}
JSON

describe Hetzner::Network do
  it "parses range, subnets and servers" do
    network = Hetzner::NetworksList.from_json(NETWORK_JSON).networks.first
    network.ip_range.should eq("10.0.0.0/16")
    network.servers.should eq([119727691_i64, 119727720_i64])
    network.cloud_subnet.not_nil!.gateway.should eq("10.0.0.1")
    vs = network.vswitch_subnet.not_nil!
    vs.ip_range.should eq("10.1.0.0/24")
    vs.vswitch_id.should eq(4321_i64)
  end

  it "tolerates a response without subnets" do
    network = Hetzner::Network.from_json(%({"id":1,"name":"n","ip_range":"10.0.0.0/16"}))
    network.subnets.should be_empty
    network.vswitch_subnet.should be_nil
  end
end
