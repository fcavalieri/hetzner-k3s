require "../configuration/main"

# When a Robot vSwitch is in the node-to-node path the whole cluster must assume its MTU
# (Hetzner: lowest MTU on the path). nil means "let the CNI autodetect", today's behaviour.
module Kubernetes::NetworkMTU
  def self.for(settings : Configuration::Main) : Int32?
    settings.networking.private_network.vswitch.try(&.mtu)
  end
end
