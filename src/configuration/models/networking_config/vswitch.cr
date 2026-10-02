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

  def network_address : String
    network.network.address
  end

  def broadcast_address : String
    network.broadcast.address
  end

  # Called with user input (a node's private_ip): IPv6 or garbage, on either side, is "no".
  def contains?(ip : String) : Bool
    address = IPAddress.new(ip)
    range = IPAddress.new(subnet)
    return false unless address.is_a?(IPAddress::IPv4) && range.is_a?(IPAddress::IPv4)

    value = address.to_u32
    value >= range.network_u32 && value <= range.broadcast_u32
  rescue ArgumentError
    false
  end

  private def network : IPAddress::IPv4
    IPAddress.new(subnet).as(IPAddress::IPv4)
  end
end
