require "yaml"
require "ipaddress"

class Configuration::Models::NetworkingConfig::VSwitch
  include YAML::Serializable
  include YAML::Serializable::Unmapped

  getter vlan : Int32
  getter subnet : String
  getter name : String = ""
  getter existing_vswitch_id : Int32?
  getter mtu : Int32 = 1400

  def initialize(@vlan, @subnet, @name = "", @existing_vswitch_id = nil, @mtu = 1400)
  end

  def name_for(cluster_name : String) : String
    name.blank? ? cluster_name : name
  end

  # Hetzner uses the first host address of the vSwitch subnet as its gateway.
  def gateway : String
    network.first.to_s
  end

  def prefix : Int32
    network.prefix.to_i
  end

  def netmask : String
    network.netmask
  end

  def contains?(ip : String) : Bool
    value = IPAddress.new(ip).as(IPAddress::IPv4).to_u32
    value >= network.network_u32 && value <= network.broadcast_u32
  rescue ArgumentError
    false
  end

  private def network : IPAddress::IPv4
    IPAddress.new(subnet).as(IPAddress::IPv4)
  end
end
