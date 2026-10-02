require "base64"
require "crinja"
require "../../configuration/main"
require "../../configuration/models/external_node"

# The VLAN interface a Robot node needs to reach the cloud private network through the
# vSwitch, following Hetzner's "connect dedicated server via vSwitch" guide: tagged VLAN on
# the public NIC, MTU 1400, an address from the vSwitch subnet, a route for the whole
# network range via the vSwitch subnet gateway.
class Kubernetes::Worker::VlanSetup
  NETPLAN_TEMPLATE    = {{ read_file("#{__DIR__}/../../../templates/vswitch_netplan.yaml") }}
  INTERFACES_TEMPLATE = {{ read_file("#{__DIR__}/../../../templates/vswitch_interfaces") }}

  NETPLAN_PATH    = "/etc/netplan/60-hetzner-k3s-vswitch.yaml"
  INTERFACES_PATH = "/etc/network/interfaces.d/hetzner-k3s-vswitch"

  DETECT_PARENT_COMMAND    = "ip -o -4 route show default | awk '{print $5}' | head -n1"
  DETECT_MECHANISM_COMMAND = "if [ -d /etc/netplan ]; then echo netplan; elif [ -d /etc/network ]; then echo ifupdown; else echo none; fi"

  private getter settings : Configuration::Main
  private getter node : Configuration::Models::ExternalNode
  private getter vswitch : Configuration::Models::NetworkingConfig::VSwitch

  def initialize(@settings, @node)
    @vswitch = settings.networking.private_network.vswitch.not_nil!
  end

  def interface_name(parent : String) : String
    "#{parent}.#{vswitch.vlan}"
  end

  def render(mechanism : String, parent : String) : String
    template = mechanism == "netplan" ? NETPLAN_TEMPLATE : INTERFACES_TEMPLATE
    # Crinja drops the trailing newline; config files should end with one.
    Crinja.render(template, {
      vlan_interface:   interface_name(parent),
      vlan_id:          vswitch.vlan,
      parent_interface: parent,
      mtu:              vswitch.mtu,
      private_ip:       node.private_ip.not_nil!,
      prefix:           vswitch.prefix,
      netmask:          vswitch.netmask,
      ip_range:         settings.networking.private_network.effective_ip_range,
      gateway:          vswitch.gateway,
    }) + "\n"
  end

  # One root shell script: write the file, bring the interface up, pin the MTU
  # (Hetzner documents a netplan MTU glitch), verify the address is there.
  def apply_command(mechanism : String, parent : String) : String
    iface = interface_name(parent)
    content = Base64.strict_encode(render(mechanism, parent))
    verify = "ip -4 -o addr show dev #{iface} | grep -q ' #{node.private_ip}/' || { echo 'ERROR: #{iface} did not come up with #{node.private_ip}' >&2; exit 1; }"

    case mechanism
    when "netplan"
      <<-SCRIPT
      set -e
      echo '#{content}' | base64 -d > #{NETPLAN_PATH}
      chmod 600 #{NETPLAN_PATH}
      netplan generate
      netplan apply
      sleep 2
      ip link set #{iface} mtu #{vswitch.mtu}
      #{verify}
      SCRIPT
    when "ifupdown"
      <<-SCRIPT
      set -e
      export DEBIAN_FRONTEND=noninteractive
      dpkg -s vlan >/dev/null 2>&1 || apt-get install -y -qq vlan
      mkdir -p /etc/network/interfaces.d
      grep -qE '^source(-directory)? /etc/network/interfaces\\.d' /etc/network/interfaces || echo 'source /etc/network/interfaces.d/*' >> /etc/network/interfaces
      echo '#{content}' | base64 -d > #{INTERFACES_PATH}
      ifdown #{iface} 2>/dev/null || true
      ifup #{iface}
      ip link set #{iface} mtu #{vswitch.mtu}
      #{verify}
      SCRIPT
    else
      raise "unsupported network mechanism '#{mechanism}' on external node #{node.host}: only netplan and ifupdown are supported"
    end
  end

  def reachability_command(master_private_ip : String) : String
    "ping -c 2 -W 2 #{master_private_ip} >/dev/null && timeout 5 bash -c '</dev/tcp/#{master_private_ip}/6443' 2>/dev/null"
  end

  def self.cleanup_command(vlan : Int32) : String
    <<-SCRIPT
    rm -f #{NETPLAN_PATH} #{INTERFACES_PATH}
    for link in $(ip -o link show type vlan 2>/dev/null | awk -F': ' '{print $2}' | cut -d@ -f1 | grep "\\.#{vlan}$"); do ip link del "$link" 2>/dev/null || true; done
    command -v netplan >/dev/null 2>&1 && netplan apply 2>/dev/null || true
    SCRIPT
  end
end
