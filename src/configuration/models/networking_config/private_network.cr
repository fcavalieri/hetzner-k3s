require "ipaddress"
require "./vswitch"

class Configuration::Models::NetworkingConfig::PrivateNetwork
  include YAML::Serializable
  include YAML::Serializable::Unmapped

  getter enabled : Bool = true
  getter subnet : String = "10.0.0.0/16"
  getter ip_range : String?
  getter existing_network_name : String = ""
  getter vswitch : Configuration::Models::NetworkingConfig::VSwitch?

  def initialize
  end

  # The network's range; the cloud subnet when no wider range is configured.
  def effective_ip_range : String
    ip_range || subnet
  end

  # Hetzner reserves the first host address of the network range as its gateway.
  def gateway : String
    IPAddress.new(effective_ip_range).as(IPAddress::IPv4).first.to_s
  end
end
