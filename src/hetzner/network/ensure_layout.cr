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

  private def run_action(path : String, params, what : String)
    Retriable.retry(max_attempts: 10, backoff: false, base_interval: 5.seconds) do
      success, response = hetzner_client.post(path, params)

      unless success
        STDERR.puts "[#{default_log_prefix}] Failed to #{what}: #{response}"
        STDERR.puts "[#{default_log_prefix}] Retrying to #{what} in 5 seconds..."
        raise "Failed to #{what}"
      end
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
