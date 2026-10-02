require "../spec_helper"
require "../../src/hetzner/robot/client"

class RecordingRobotClient < Hetzner::Robot::Client
  getter calls = [] of String
  property responses = {} of String => Tuple(Bool, String)

  def initialize
    super("user", "password")
  end

  private def get(path)
    calls << "GET #{path}"
    responses["GET #{path}"]
  end

  private def post(path, params)
    calls << "POST #{path} #{params.to_a.sort.map { |k, v| "#{k}=#{v}" }.join("&")}"
    responses["POST #{path}"]
  end

  private def post_form(path, body : String)
    calls << "POST #{path} #{body}"
    responses["POST #{path}"]
  end

  private def delete_form(path, body : String)
    calls << "DELETE #{path} #{body}"
    responses["DELETE #{path}"]
  end
end

VSWITCH_DETAIL = %({"id":4321,"name":"test","vlan":4000,"cancelled":false,
  "server":[{"server_ip":"1.2.3.4","server_ipv6_net":"::","server_number":42,"status":"ready"},
            {"server_ip":"5.6.7.8","server_ipv6_net":"::","server_number":43,"status":"in process"}],
  "subnet":[],"cloud_network":[{"id":11898291,"ip":"10.1.0.0","mask":24,"gateway":"10.1.0.1"}]})

describe Hetzner::Robot::Client do
  it "lists vswitches" do
    client = RecordingRobotClient.new
    client.responses["GET /vswitch"] = {true, %([{"id":4321,"name":"test","vlan":4000,"cancelled":false}])}
    list = client.vswitches
    list.size.should eq(1)
    list.first.name.should eq("test")
    list.first.servers.should be_empty
  end

  it "reads one vswitch with its servers" do
    client = RecordingRobotClient.new
    client.responses["GET /vswitch/4321"] = {true, VSWITCH_DETAIL}
    vswitch = client.vswitch(4321)
    vswitch.vlan.should eq(4000)
    vswitch.server_numbers.should eq([42, 43])
    vswitch.servers.last.status.should eq("in process")
  end

  it "creates a vswitch" do
    client = RecordingRobotClient.new
    client.responses["POST /vswitch"] = {true, %({"id":4321,"name":"test","vlan":4000,"cancelled":false,"server":[],"subnet":[],"cloud_network":[]})}
    client.create_vswitch("test", 4000).id.should eq(4321)
    client.calls.should eq(["POST /vswitch name=test&vlan=4000"])
  end

  it "adds and removes servers with the Robot array encoding" do
    Hetzner::Robot::Client.servers_form_body([42, 43]).should eq("server[]=42&server[]=43")
    client = RecordingRobotClient.new
    client.responses["POST /vswitch/4321/server"] = {true, ""}
    client.responses["DELETE /vswitch/4321/server"] = {true, ""}
    client.add_vswitch_servers(4321, [42, 43])
    client.remove_vswitch_servers(4321, [42])
    client.calls.should eq(["POST /vswitch/4321/server server[]=42&server[]=43", "DELETE /vswitch/4321/server server[]=42"])
  end

  it "raises a Client::Error with the Robot message on failure" do
    client = RecordingRobotClient.new
    client.responses["POST /vswitch/4321/server"] = {false, %({"error":{"status":409,"code":"VSWITCH_IN_PROCESS","message":"busy"}})}
    expect_raises(Hetzner::Robot::Client::Error, /VSWITCH_IN_PROCESS/) { client.add_vswitch_servers(4321, [42]) }
  end
end
