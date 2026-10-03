require "../configuration/main"

# When a Robot vSwitch is in the node-to-node path the whole cluster must assume its MTU
# (Hetzner: lowest MTU on the path). nil means "let the CNI autodetect", today's behaviour;
# also when the private network is disabled, since no vSwitch is in the path then.
module Kubernetes::NetworkMTU
  def self.for(settings : Configuration::Main) : Int32?
    private_network = settings.networking.private_network
    return nil unless private_network.enabled

    private_network.vswitch.try(&.mtu)
  end
end
