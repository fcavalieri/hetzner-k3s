require "json"

class Hetzner::NetworkSubnet
  include JSON::Serializable

  property type : String
  property ip_range : String
  property network_zone : String
  property gateway : String?
  property vswitch_id : Int64?

  def vswitch? : Bool
    type == "vswitch"
  end
end
