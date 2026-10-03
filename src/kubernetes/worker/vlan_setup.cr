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

  # The vSwitch can take minutes to forward traffic after Robot reports it ready.
  REACHABILITY_INTERVAL = 10.seconds
  REACHABILITY_ATTEMPTS = 13 # the first try, then one every 10 s for 120 s

  private getter settings : Configuration::Main
  private getter node : Configuration::Models::ExternalNode
  private getter vswitch : Configuration::Models::NetworkingConfig::VSwitch

  def initialize(@settings, @node)
    @vswitch = settings.networking.private_network.vswitch.not_nil!
  end

  # `vlan<id>`, whatever the parent: Linux caps interface names at 15 characters, and Hetzner
  # NIC names such as enp5s0f0np0 leave no room for a `.<id>` suffix. ifupdown's vlan hook
  # reads the id from a `vlanNNNN` name; netplan takes it from `id`.
  def self.interface_name_for(vlan : Int32) : String
    "vlan#{vlan}"
  end

  def interface_name : String
    self.class.interface_name_for(vswitch.vlan)
  end

  def render(mechanism : String, parent : String) : String
    template = mechanism == "netplan" ? NETPLAN_TEMPLATE : INTERFACES_TEMPLATE
    # Crinja drops the trailing newline; config files should end with one.
    Crinja.render(template, {
      vlan_interface:   interface_name,
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

  # One root shell script. The rendered file goes to a temp path first: when it matches the
  # live file and the address is already on the interface, nothing is applied ("unchanged"),
  # so a re-run never bounces the interface. Otherwise it is installed and applied, the MTU is
  # pinned (Hetzner documents a netplan MTU glitch) and the address verified. A file netplan
  # or ifup rejects is removed again, so no broken configuration is left for the next boot.
  def apply_command(mechanism : String, parent : String) : String
    case mechanism
    when "netplan"
      <<-SCRIPT
      set -e
      #{stage_and_compare(mechanism, parent, NETPLAN_PATH)}
      install -m 600 "$TMP" #{NETPLAN_PATH}
      netplan generate || { rm -f #{NETPLAN_PATH}; echo 'ERROR: netplan generate rejected the vSwitch configuration; removed #{NETPLAN_PATH}' >&2; exit 1; }
      netplan apply
      sleep 2
      #{mtu_command}
      #{verify_command}
      SCRIPT
    when "ifupdown"
      <<-SCRIPT
      set -e
      export DEBIAN_FRONTEND=noninteractive
      dpkg -s vlan >/dev/null 2>&1 || apt-get install -y -qq vlan
      mkdir -p /etc/network/interfaces.d
      grep -qE '^source(-directory)? /etc/network/interfaces\\.d' /etc/network/interfaces || echo 'source /etc/network/interfaces.d/*' >> /etc/network/interfaces
      #{stage_and_compare(mechanism, parent, INTERFACES_PATH)}
      ifdown #{interface_name} 2>/dev/null || true
      install -m 644 "$TMP" #{INTERFACES_PATH}
      ifup #{interface_name} || { rm -f #{INTERFACES_PATH}; echo 'ERROR: ifup #{interface_name} failed; removed #{INTERFACES_PATH}' >&2; exit 1; }
      #{mtu_command}
      #{verify_command}
      SCRIPT
    else
      raise "unsupported network mechanism '#{mechanism}' on external node #{node.host}: only netplan and ifupdown are supported"
    end
  end

  # Run after `netplan apply` dropped the SSH session: finish what the apply script could not.
  def recovery_command : String
    "set -e\n#{mtu_command}\n#{verify_command}"
  end

  def reachability_command(master_private_ip : String) : String
    "ping -c 2 -W 2 #{master_private_ip} >/dev/null && timeout 5 bash -c '</dev/tcp/#{master_private_ip}/6443' 2>/dev/null"
  end

  # Util::SSH reports ssh's own exit status, and ssh exits 255 when the connection fails or
  # drops; any other status is the remote command's own failure and is never recovered.
  def self.session_dropped?(message : String) : Bool
    message.includes?("(exit code: 255)")
  end

  # Runs the block until it succeeds, at most `attempts` times, waiting `interval` after each
  # failure (on_retry gets the failed attempt's number first); re-raises the last failure.
  def self.with_retries(attempts : Int32, interval : Time::Span, on_retry : Int32 -> Nil = ->(_attempt : Int32) { nil }, &)
    attempt = 1
    loop do
      begin
        return yield
      rescue ex
        raise ex if attempt >= attempts
        on_retry.call(attempt)
        sleep interval
        attempt += 1
      end
    end
  end

  def self.cleanup_command(vlan : Int32) : String
    <<-SCRIPT
    rm -f #{NETPLAN_PATH} #{INTERFACES_PATH}
    ip link del #{interface_name_for(vlan)} 2>/dev/null || true
    command -v netplan >/dev/null 2>&1 && netplan apply 2>/dev/null || true
    SCRIPT
  end

  private def stage_and_compare(mechanism : String, parent : String, path : String) : String
    <<-SCRIPT
    TMP=$(mktemp)
    trap 'rm -f "$TMP"' EXIT
    echo '#{Base64.strict_encode(render(mechanism, parent))}' | base64 -d > "$TMP"
    if cmp -s "$TMP" #{path} && #{address_present_command}; then
      echo unchanged
      exit 0
    fi
    SCRIPT
  end

  private def address_present_command : String
    "ip -4 -o addr show dev #{interface_name} 2>/dev/null | grep -q ' #{node.private_ip}/'"
  end

  private def mtu_command : String
    "ip link set #{interface_name} mtu #{vswitch.mtu}"
  end

  private def verify_command : String
    "ip -4 -o addr show dev #{interface_name} | grep -q ' #{node.private_ip}/' || { echo 'ERROR: #{interface_name} did not come up with #{node.private_ip}' >&2; exit 1; }"
  end
end
