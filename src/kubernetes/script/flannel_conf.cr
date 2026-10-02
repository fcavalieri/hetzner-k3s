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

  def self.render(settings : Configuration::Main) : String
    mtu = Kubernetes::NetworkMTU.for(settings)
    return "" if mtu.nil? || !settings.networking.cni.flannel?

    backend = if wireguard?(settings)
                %({"Type": "wireguard", "PersistentKeepaliveInterval": 25, "MTU": #{mtu}})
              else
                %({"Type": "vxlan", "MTU": #{mtu}})
              end

    Crinja.render(TEMPLATE, {cluster_cidr: settings.networking.cluster_cidr, backend_json: backend})
  end
end
