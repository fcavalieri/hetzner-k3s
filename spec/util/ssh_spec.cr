require "../spec_helper"
require "../../src/util/ssh"
require "../../src/hetzner/instance"
require "../../src/kubernetes/worker/vlan_setup"

describe Util::SSH do
  it "names the exit code when a command fails" do
    Util::SSH.failure_message("node-1", 3, "boom").should eq("SSH command failed on node-1 (exit code: 3): boom")
  end

  it "reports a connection-level failure as exit code 255" do
    instance = Hetzner::Instance.new(0, "running", "unreachable", "127.0.0.1", "127.0.0.1")
    error = expect_raises(IO::Error, /\(exit code: 255\)/) do
      Util::SSH.new("/nonexistent-key").run(instance, 1, "true", false, print_output: false)
    end
    Kubernetes::Worker::VlanSetup.session_dropped?(error.message.to_s).should be_true
  end
end
