require "ipaddress"
require "../../main"
require "../../models/networking_config/private_network"
require "../node_pool_config/location"

class Configuration::Validators::NetworkingConfig::VSwitch
  getter errors : Array(String)
  getter private_network : Configuration::Models::NetworkingConfig::PrivateNetwork
  getter settings : Configuration::Main

  def initialize(@errors, @private_network, @settings)
  end

  def validate
    validate_ip_range

    vswitch = private_network.vswitch
    if vswitch.nil?
      errors << "networking.private_network.vswitch is required when a Robot external node pool uses the private network" if settings.robot_private_network?
      return
    end

    validate_vlan_and_mtu(vswitch)
    validate_vswitch_subnet(vswitch)
    validate_zone
    validate_cni
  end

  private def validate_ip_range
    range = private_network.ip_range
    return if range.nil?

    ip_range = parse(range)
    subnet = parse(private_network.subnet)
    return errors << "private network ip_range #{range} is not a valid network in CIDR notation" if ip_range.nil?
    return if subnet.nil?

    errors << "private network ip_range #{range} must contain subnet #{private_network.subnet}" unless contains_network?(ip_range, subnet)
  end

  private def validate_vlan_and_mtu(vswitch)
    errors << "vswitch.vlan must be between 4000 and 4091" unless (4000..4091).includes?(vswitch.vlan)
    errors << "vswitch.mtu must be between 1280 and 1400" unless (1280..1400).includes?(vswitch.mtu)
  end

  private def validate_vswitch_subnet(vswitch)
    vs = parse(vswitch.subnet)
    return errors << "vswitch.subnet #{vswitch.subnet} is not a valid network in CIDR notation" if vs.nil?

    range = parse(private_network.effective_ip_range)
    cloud = parse(private_network.subnet)
    return if range.nil? || cloud.nil?

    errors << "vswitch.subnet #{vswitch.subnet} must be inside the private network ip_range #{private_network.effective_ip_range}" unless contains_network?(range, vs)
    errors << "vswitch.subnet #{vswitch.subnet} must not overlap the cloud subnet #{private_network.subnet}" if contains_network?(vs, cloud) || contains_network?(cloud, vs)
    errors << "vswitch.subnet #{vswitch.subnet} must not contain the first address of ip_range (#{range.first})" if vswitch.contains?(range.first.to_s)
  end

  private def validate_zone
    location = settings.masters_pool.locations.first
    zone = ::Configuration::Validators::NodePoolConfig::Location.network_zone_by_location(location)
    errors << "vswitch coupling is only available in the eu-central network zone (masters are in #{location}, zone #{zone})" unless zone == "eu-central"
  end

  private def validate_cni
    return unless settings.robot_private_network?
    return unless settings.networking.cni.cilium? && settings.networking.cni.cilium.routing_mode == "native"

    errors << "Cilium native routing cannot be used with Robot nodes on the private network: the CCM route controller is disabled for vSwitch setups, use routing_mode tunnel"
  end

  private def parse(cidr : String) : IPAddress::IPv4?
    ip = IPAddress.new(cidr)
    ip.is_a?(IPAddress::IPv4) ? ip : nil
  rescue ArgumentError
    nil
  end

  # outer contains inner when inner's first and last addresses both fall inside outer
  private def contains_network?(outer : IPAddress::IPv4, inner : IPAddress::IPv4) : Bool
    inner.network_u32 >= outer.network_u32 && inner.broadcast_u32 <= outer.broadcast_u32
  end
end
