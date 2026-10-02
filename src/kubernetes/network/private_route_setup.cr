require "../../configuration/main"
require "../../hetzner/instance"
require "../../util"
require "../../util/ssh"

# Cloud nodes learn the route for the private network range from Hetzner's DHCP. After the
# range was extended, that route is stale until the next lease renewal, so it is set here on
# the interface that already reaches the network gateway. DHCP keeps it correct afterwards.
class Kubernetes::Network::PrivateRouteSetup
  include Util

  private getter settings : Configuration::Main
  private getter ssh : ::Util::SSH

  def initialize(@settings, @ssh)
  end

  def self.command(ip_range : String, gateway : String) : String
    "IFACE=$(ip -o -4 route get #{gateway} | awk '{for (i = 1; i <= NF; i++) if ($i == \"dev\") print $(i + 1)}' | head -n1); " \
    "[ -n \"$IFACE\" ] && ip route replace #{ip_range} via #{gateway} dev \"$IFACE\" && echo \"route #{ip_range} via #{gateway} dev $IFACE\""
  end

  def needed? : Bool
    private_network = settings.networking.private_network
    private_network.enabled && (!private_network.ip_range.nil? || !private_network.vswitch.nil?)
  end

  def deploy(instances : Array(Hetzner::Instance)) : Nil
    return unless needed?

    private_network = settings.networking.private_network
    command = self.class.command(private_network.effective_ip_range, private_network.gateway)

    instances.each do |instance|
      log_line "Ensuring route #{private_network.effective_ip_range} via #{private_network.gateway}...", instance.name
      ssh.run(instance, settings.networking.ssh.port, command, settings.networking.ssh.use_agent, print_output: false)
    end
  end

  private def default_log_prefix
    "Private Route"
  end
end
