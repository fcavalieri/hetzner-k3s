require "ipaddress"
require "retriable"
require "../client"
require "../network"
require "./find"
require "../../util"
require "../../configuration/main"

# Brings an existing private network to the configured layout: a wider ip_range (extend only)
# and the vSwitch subnet. Never removes or replaces anything; conflicts raise. Each step runs
# only when its key is set explicitly, so a configuration without the new keys never touches
# the network (an existing network may well be wider than `subnet`).
class Hetzner::Network::EnsureLayout
  include Util

  # Raised inside run_action for failures worth another attempt; anything else propagates at once.
  class RetryableActionError < Exception; end

  ATTACHED_RESOURCES_MESSAGE = "network has attached resources"

  WAIT_ATTEMPTS = 12
  WAIT_INTERVAL = 5.seconds

  private getter settings : Configuration::Main
  private getter hetzner_client : Hetzner::Client
  private getter network : Hetzner::Network
  private getter network_zone : String
  private getter vswitch_id : Int32?

  def initialize(@settings, @hetzner_client, @network, @network_zone, @vswitch_id)
  end

  # True when the configuration asks for a layout change: an explicit ip_range or a vswitch.
  def self.needed?(settings : Configuration::Main) : Bool
    private_network = settings.networking.private_network
    !private_network.ip_range.nil? || !private_network.vswitch.nil?
  end

  def run : Hetzner::Network
    extend_ip_range_if_needed
    add_vswitch_subnet_if_needed
    refresh
  end

  private def extend_ip_range_if_needed
    desired = settings.networking.private_network.ip_range
    current = network.ip_range
    return if desired.nil? || current.empty? || current == desired

    unless contains?(desired, current)
      raise "Private network #{network.name} has ip_range #{current}, which the configured ip_range #{desired} does not contain; Hetzner networks can only be extended, never shrunk or moved"
    end

    # Hetzner refuses change_ip_range as soon as one server or load balancer is attached (undocumented;
    # verified 2026-10-03). Say so up front, with the members, instead of discovering it ten retries later.
    attached = attached_resources
    raise attached_resources_message(current, desired, attached) unless attached.empty?

    log_line "Extending private network #{network.name} from #{current} to #{desired}..."
    run_action("/networks/#{network.id}/actions/change_ip_range", {:ip_range => desired}, "extend private network")
    wait_until("ip_range #{desired}") { |refreshed| refreshed.ip_range == desired }
    log_line "...private network extended"
  end

  private def add_vswitch_subnet_if_needed
    config = settings.networking.private_network.vswitch
    id = vswitch_id
    return if config.nil? || id.nil?

    if existing = network.vswitch_subnet
      unless existing.vswitch_id == id.to_i64 && existing.ip_range == config.subnet
        raise "Private network #{network.name} already has a vSwitch subnet #{existing.ip_range} (vSwitch #{existing.vswitch_id}) but the configuration says #{config.subnet} (vSwitch #{id}); remove it by hand if that is intended"
      end
      return
    end

    log_line "Adding vSwitch subnet #{config.subnet} (vSwitch #{id}) to private network #{network.name}..."
    run_action("/networks/#{network.id}/actions/add_subnet",
      {:type => "vswitch", :ip_range => config.subnet, :network_zone => network_zone, :vswitch_id => id},
      "add vSwitch subnet")
    wait_until("vSwitch subnet #{config.subnet}") { |refreshed| !refreshed.vswitch_subnet.nil? }
    log_line "...vSwitch subnet added"
  end

  private def attached_resources : String
    parts = [] of String
    parts << "servers #{network.servers.join(", ")}" unless network.servers.empty?
    parts << "load balancers #{network.load_balancers.join(", ")}" unless network.load_balancers.empty?
    parts.join("; ")
  end

  private def attached_resources_message(current : String, desired : String, attached : String) : String
    "Hetzner refuses to change the ip_range of private network #{network.name} (#{current} -> #{desired}) while resources are attached: #{attached}. " \
    "Detach every member, extend the range and re-attach each member with its original IP; scripts/extend-network-range.sh in the hetzner-k3s repository does exactly that " \
    "(about a minute without private-network connectivity, and the flannel VXLAN device is lost until k3s restarts on every node, which `create` then does). Run create again afterwards."
  end

  private def run_action(path : String, params, what : String)
    Retriable.retry(on: RetryableActionError, max_attempts: 10, backoff: false, base_interval: 5.seconds) do
      success, response = hetzner_client.post(path, params)
      next if success

      STDERR.puts "[#{default_log_prefix}] Failed to #{what}: #{response}"
      raise "Failed to #{what}: #{attached_resources_message(network.ip_range, settings.networking.private_network.effective_ip_range, attached_resources.presence || "see the Hetzner console")}" if response.includes?(ATTACHED_RESOURCES_MESSAGE)

      STDERR.puts "[#{default_log_prefix}] Retrying to #{what} in 5 seconds..."
      raise RetryableActionError.new("Failed to #{what}")
    end
  end

  # Hetzner network actions are asynchronous; poll until the network shows the change.
  private def wait_until(what : String, &block : Hetzner::Network -> Bool)
    WAIT_ATTEMPTS.times do
      return if yield refresh
      sleep WAIT_INTERVAL
    end
    raise "Private network #{network.name} did not show #{what} after #{WAIT_ATTEMPTS * WAIT_INTERVAL.total_seconds.to_i} seconds"
  end

  private def refresh : Hetzner::Network
    Hetzner::Network::Find.new(hetzner_client, network.name).run.not_nil!
  end

  private def contains?(outer : String, inner : String) : Bool
    outer_net = IPAddress.new(outer).as(IPAddress::IPv4)
    inner_net = IPAddress.new(inner).as(IPAddress::IPv4)
    inner_net.network_u32 >= outer_net.network_u32 && inner_net.broadcast_u32 <= outer_net.broadcast_u32
  end

  private def default_log_prefix
    "Private Network"
  end
end
