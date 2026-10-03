require "retriable"
require "../client"
require "../network"
require "./find"
require "../../util"

# Removes the vSwitch subnet from a network that outlives the cluster (existing_network_name),
# before the vSwitch it couples is detached or deleted. A network without a vSwitch subnet of
# that range is left alone.
class Hetzner::Network::DeleteSubnet
  include Util

  WAIT_ATTEMPTS = 12
  WAIT_INTERVAL = 5.seconds

  private getter hetzner_client : Hetzner::Client
  private getter network : Hetzner::Network
  private getter ip_range : String

  def initialize(@hetzner_client, @network, @ip_range)
  end

  # Returns true when a subnet was removed.
  def run : Bool
    return false unless vswitch_subnet?(network)

    log_line "Removing vSwitch subnet #{ip_range} from private network #{network.name}..."
    Retriable.retry(max_attempts: 10, backoff: false, base_interval: 5.seconds) do
      success, response = hetzner_client.post("/networks/#{network.id}/actions/delete_subnet", {:ip_range => ip_range})

      unless success
        STDERR.puts "[#{default_log_prefix}] Failed to remove vSwitch subnet: #{response}"
        STDERR.puts "[#{default_log_prefix}] Retrying to remove vSwitch subnet in 5 seconds..."
        raise "Failed to remove vSwitch subnet"
      end
    end
    wait_until_removed
    log_line "...vSwitch subnet removed"
    true
  end

  private def vswitch_subnet?(candidate : Hetzner::Network) : Bool
    candidate.subnets.any? { |subnet| subnet.vswitch? && subnet.ip_range == ip_range }
  end

  # Hetzner network actions are asynchronous; the vSwitch cleanup that follows needs it gone.
  private def wait_until_removed
    WAIT_ATTEMPTS.times do
      refreshed = Hetzner::Network::Find.new(hetzner_client, network.name).run
      return if refreshed.nil? || !vswitch_subnet?(refreshed)
      sleep WAIT_INTERVAL
    end
    raise "Private network #{network.name} still shows vSwitch subnet #{ip_range} after #{WAIT_ATTEMPTS * WAIT_INTERVAL.total_seconds.to_i} seconds"
  end

  private def default_log_prefix
    "Private Network"
  end
end
