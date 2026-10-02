require "./spec_helper"
require "../src/version"

describe Hetzner::K3s do
  it "carries the fork version" do
    Hetzner::K3s::VERSION.should eq("2.6.0-fcav.1")
  end
end
