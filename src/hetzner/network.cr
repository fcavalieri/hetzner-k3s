require "json"
require "./network_subnet"

class Hetzner::Network
  include JSON::Serializable

  property id : Int64
  property name : String
  property ip_range : String = ""
  property subnets : Array(Hetzner::NetworkSubnet) = [] of Hetzner::NetworkSubnet
  property servers : Array(Int64) = [] of Int64
  property load_balancers : Array(Int64) = [] of Int64

  def vswitch_subnet : Hetzner::NetworkSubnet?
    subnets.find(&.vswitch?)
  end

  def cloud_subnet : Hetzner::NetworkSubnet?
    subnets.find { |subnet| subnet.type == "cloud" || subnet.type == "server" }
  end
end
