require "../../src/k3s"

module K3s
  def self.available_releases
    ["v1.23.5+k3s1", "v1.23.6+k3s1", "v1.36.1+k3s1"]
  end

  def self.preset_token(token : String)
    @@k3s_token = token
  end
end
