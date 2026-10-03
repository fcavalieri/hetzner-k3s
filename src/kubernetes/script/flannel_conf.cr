require "crinja"
require "../../configuration/main"
require "../network_mtu"

# The flannel net-conf k3s gets through --flannel-conf. Same shape k3s writes itself
# (pkg/agent/flannel/setup.go) plus the backend MTU; the backend type mirrors what
# MasterGenerator#flannel_backend selects.
module Kubernetes::Script::FlannelConf
  TEMPLATE = {{ read_file("#{__DIR__}/../../../templates/flannel_net_conf.json") }}
  PATH     = "/etc/rancher/k3s/flannel-net-conf.json"

  def self.wireguard?(settings : Configuration::Main) : Bool
    settings.networking.cni.flannel? && settings.networking.cni.encryption?
  end

  # VXLAN header overhead flannel subtracts from the backend MTU for its flannel.1 device.
  VXLAN_OVERHEAD = 50

  # The MTU flannel gives flannel.1 under the rendered configuration, as a string for the
  # install scripts; "" when no configuration is rendered or the backend is not VXLAN (the
  # wireguard backend uses its own device). flannel never resizes an existing flannel.1, so
  # the scripts delete a device with another MTU before (re)starting k3s (production rollout
  # 2026-10-03: the workers kept MTU 1400 through a re-install).
  def self.vxlan_device_mtu(settings : Configuration::Main) : String
    mtu = Kubernetes::NetworkMTU.for(settings)
    return "" if mtu.nil? || !settings.networking.cni.flannel? || wireguard?(settings)

    (mtu - VXLAN_OVERHEAD).to_s
  end

  def self.render(settings : Configuration::Main) : String
    mtu = Kubernetes::NetworkMTU.for(settings)
    return "" if mtu.nil? || !settings.networking.cni.flannel?

    # "wireguard" is flannel's registered backend name; "wireguard-native" is only the k3s CLI
    # flag value. k3s itself writes {"Type": "wireguard", ...} for --flannel-backend=wireguard-native
    # (pkg/agent/flannel/setup.go), so the type string must not follow flannel_backend's flag.
    backend = if wireguard?(settings)
                %({"Type": "wireguard", "PersistentKeepaliveInterval": 25, "MTU": #{mtu}})
              else
                %({"Type": "vxlan", "MTU": #{mtu}})
              end

    Crinja.render(TEMPLATE, {cluster_cidr: settings.networking.cluster_cidr, backend_json: backend})
  end
end
