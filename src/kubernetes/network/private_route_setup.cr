require "../../configuration/main"
require "../../hetzner/instance"
require "../../util"
require "../../util/ssh"

# Cloud nodes learn the route for the private network range from Hetzner's DHCP. After the
# range was extended, that route is stale until the next lease renewal, so it is set here on
# the interface that already reaches the network gateway. DHCP keeps it correct afterwards.
class Kubernetes::Network::PrivateRouteSetup
  include Util

  NODE_IPS_COMMAND = %(KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl get nodes -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="ExternalIP")].address}{"\\n"}{end}' 2>/dev/null || true)

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

  # The cluster's node IPs that belong to neither a known instance nor an external node.
  def self.autoscaled_ips(node_ips : Array(String), known_instances : Array(Hetzner::Instance), external_hosts : Array(String)) : Array(String)
    known = known_instances.flat_map { |instance| [instance.public_ip_address, instance.private_ip_address].compact }
    node_ips.map(&.strip).reject(&.empty?) - known - external_hosts
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

  # Autoscaled cloud nodes are not among the instances create knows about; they are found the
  # way LocalFirewall::Setup#deploy_to_all_nodes finds them, from the nodes' ExternalIPs. A
  # node that cannot be reached is reported and skipped: DHCP fixes its route on renewal.
  def deploy_to_autoscaled(first_master : Hetzner::Instance, known_instances : Array(Hetzner::Instance)) : Nil
    return unless needed?

    output = ssh.run(first_master, settings.networking.ssh.port, NODE_IPS_COMMAND, settings.networking.ssh.use_agent, print_output: false)
    autoscaled = self.class.autoscaled_ips(output.lines, known_instances, external_hosts)
    return if autoscaled.empty?

    private_network = settings.networking.private_network
    command = self.class.command(private_network.effective_ip_range, private_network.gateway)

    autoscaled.each do |ip|
      log_line "Ensuring route #{private_network.effective_ip_range} via #{private_network.gateway} on autoscaled node...", ip
      ssh.run(Hetzner::Instance.new(0, "running", ip, ip, ip), settings.networking.ssh.port, command, settings.networking.ssh.use_agent, print_output: false)
    rescue ex
      log_line "Failed to ensure the route on autoscaled node #{ip}, DHCP will set it on lease renewal: #{ex.message}", ip
    end
  end

  private def external_hosts : Array(String)
    settings.worker_node_pools.select(&.external?).flat_map { |pool| pool.external.try(&.nodes.map(&.host)) || [] of String }
  end

  private def default_log_prefix
    "Private Route"
  end
end
