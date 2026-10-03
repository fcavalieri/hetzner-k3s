require "../spec_helper"
require "../support/loader"
require "../../src/kubernetes/software/hetzner/cloud_controller_manager"

class PatchableCCM < Kubernetes::Software::Hetzner::CloudControllerManager
  def patch(manifest : String) : String
    patch_robot_enabled(manifest)
  end
end

CCM_MANIFEST = <<-YAML
      containers:
        - name: hcloud-cloud-controller-manager
          env:
            - name: HCLOUD_TOKEN
              valueFrom:
                secretKeyRef:
                  key: token
                  name: hcloud
            - name: ROBOT_USER
              valueFrom:
                secretKeyRef:
                  key: robot-user
                  name: hcloud
                  optional: true
            - name: ROBOT_PASSWORD
              valueFrom:
                secretKeyRef:
                  key: robot-password
                  name: hcloud
                  optional: true
YAML

ROBOT_POOL_YAML = "worker_node_pools:\n- name: robot\n  instance_type: external\n  instance_count: 1\n  external:\n    provider: robot\n    robot_user: u\n    robot_password: p\n    nodes:\n    - host: 1.2.3.4\n      robot_server_number: 42\n      private_ip: 10.1.0.2\n      ssh_user: root\n      ssh_private_key_path: /tmp/key\n      index: 1\n"
CCM_HEAD = "hetzner_token: x\ncluster_name: test\nkubeconfig_path: /tmp/k\nk3s_version: v1.36.1+k3s1\nmasters_pool:\n  instance_type: cx22\n  instance_count: 1\n"

describe Kubernetes::Software::Hetzner::CloudControllerManager do
  it "disables the route controller for Robot nodes on the private network" do
    loader = loader_for(CCM_HEAD + "networking:\n  private_network:\n    vswitch:\n      vlan: 4000\n      subnet: 10.0.1.0/24\n" + ROBOT_POOL_YAML)
    patched = PatchableCCM.new(loader, loader.settings).patch(CCM_MANIFEST)
    patched.should contain("            - name: ROBOT_ENABLED\n              value: \"true\"\n")
    patched.should contain("            - name: HCLOUD_NETWORK_ROUTES_ENABLED\n              value: \"false\"\n")
    patched.index("name: ROBOT_USER").not_nil!.should be < patched.index("name: ROBOT_ENABLED").not_nil!
  end

  it "leaves routes alone on the public network" do
    loader = loader_for(CCM_HEAD + "networking:\n  private_network:\n    enabled: false\n  public_network:\n    use_local_firewall: true\n    hetzner_ips_query_server_url: https://q.example.com\n" + ROBOT_POOL_YAML)
    patched = PatchableCCM.new(loader, loader.settings).patch(CCM_MANIFEST)
    patched.should contain("name: ROBOT_ENABLED")
    patched.should_not contain("HCLOUD_NETWORK_ROUTES_ENABLED")
  end

  it "is idempotent" do
    loader = loader_for(CCM_HEAD + "networking:\n  private_network:\n    vswitch:\n      vlan: 4000\n      subnet: 10.0.1.0/24\n" + ROBOT_POOL_YAML)
    ccm = PatchableCCM.new(loader, loader.settings)
    ccm.patch(ccm.patch(CCM_MANIFEST)).scan("HCLOUD_NETWORK_ROUTES_ENABLED").size.should eq(1)
  end
end
