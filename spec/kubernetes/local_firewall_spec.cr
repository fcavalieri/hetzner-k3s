require "../spec_helper"
require "../../src/configuration/main"
require "../../src/util/ssh"
require "../../src/kubernetes/local_firewall/setup"

class RenderableFirewall < Kubernetes::LocalFirewall::Setup
  def render(port : Int32, static : String) : String
    render_firewall_script(port, static)
  end
end

FIREWALL_SPEC_TOKEN = "hk3s-firewall-spec-token"

def firewall_settings(yaml_networking : String) : Configuration::Main
  Configuration::Main.from_yaml("hetzner_token: #{FIREWALL_SPEC_TOKEN}\ncluster_name: test\nkubeconfig_path: /tmp/k\nk3s_version: v1.36.1+k3s1\nmasters_pool:\n  instance_type: cx22\n  instance_count: 1\n" + yaml_networking)
end

# Runs only fetch_node_ips() out of the rendered script, with its readonly inputs.
def run_fetch_node_ips(script : String, static : String) : String
  body = script[/^fetch_node_ips\(\) \{.*?^\}/m]
  output = IO::Memory.new
  Process.run("bash", ["-c", "STATIC_NODE_NETWORKS='#{static}'; HETZNER_IPS_URL=http://127.0.0.1:9/ips; HETZNER_TOKEN=t; API_TIMEOUT=1; API_RETRIES=1; API_RETRY_DELAY=0; LAST_IPS_FILE=/nonexistent; #{body}; fetch_node_ips"], output: output)
  output.to_s
end

describe Kubernetes::LocalFirewall::Setup do
  it "renders static mode with the network range and no query server" do
    settings = firewall_settings("networking:\n  private_network:\n    ip_range: 10.0.0.0/15\n    subnet: 10.0.0.0/16\n")
    script = RenderableFirewall.new(settings, Util::SSH.new("/tmp/key")).render(22, "10.0.0.0/15")
    script.should contain(%(STATIC_NODE_NETWORKS="10.0.0.0/15"))
    script.should contain(%(HETZNER_IPS_URL="/ips"))
    script.should contain(%(HETZNER_TOKEN=""))
    script.should_not contain(FIREWALL_SPEC_TOKEN)
    run_fetch_node_ips(script, "10.0.0.0/15,10.1.0.0/24").should eq("10.0.0.0/15\n10.1.0.0/24\n")
  end

  it "renders poll mode unchanged on the public network" do
    settings = firewall_settings("networking:\n  private_network:\n    enabled: false\n  public_network:\n    use_local_firewall: true\n    hetzner_ips_query_server_url: https://ip-query.example.com\n")
    script = RenderableFirewall.new(settings, Util::SSH.new("/tmp/key")).render(22, "")
    script.should contain(%(HETZNER_IPS_URL="https://ip-query.example.com/ips"))
    script.should contain(%(STATIC_NODE_NETWORKS=""))
    script.should contain(%(HETZNER_TOKEN="#{FIREWALL_SPEC_TOKEN}"))
    run_fetch_node_ips(script, "").should eq("")   # unreachable server, no cache: empty, exit 1
  end
end
