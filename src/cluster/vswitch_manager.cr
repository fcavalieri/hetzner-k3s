require "../configuration/main"
require "../hetzner/robot/client"
require "../util"

class Cluster::VSwitchManager
  include Util

  POLL_INTERVAL = 10.seconds
  READY_TIMEOUT = 5.minutes

  private getter settings : Configuration::Main
  private getter robot_client : Hetzner::Robot::Client
  private getter poll_interval : Time::Span
  private getter ready_timeout : Time::Span

  def initialize(@settings, @robot_client, @poll_interval = POLL_INTERVAL, @ready_timeout = READY_TIMEOUT)
  end

  def self.for(settings : Configuration::Main) : Cluster::VSwitchManager?
    credentials = settings.robot_credentials
    return nil unless settings.robot_private_network? && credentials

    new(settings, Hetzner::Robot::Client.new(credentials[:user], credentials[:password]))
  end

  # Makes sure the vSwitch exists with every Robot node attached and ready.
  # Returns its id, or nil when no Robot pool uses the private network.
  def ensure : Int32?
    return nil unless settings.robot_private_network?

    config = settings.networking.private_network.vswitch.not_nil!
    vswitch = find_or_create(config)
    attached = attach_missing(vswitch)
    # Nothing attached: the detail fetched by find_or_create is current, so a clean re-run needs no extra read.
    wait_until_ready(vswitch.id) unless !attached && all_ready?(vswitch.servers)
    log_line "vSwitch #{vswitch.name} (#{vswitch.id}) ready with Robot server(s) #{wanted_server_numbers.join(", ")}"
    vswitch.id
  end

  # Detaches the cluster's Robot servers; deletes the vSwitch only when hetzner-k3s created it.
  def cleanup : Nil
    return unless settings.robot_private_network?

    config = settings.networking.private_network.vswitch.not_nil!
    vswitch = find(config)
    return if vswitch.nil?

    attached = vswitch.server_numbers & wanted_server_numbers
    unless attached.empty?
      log_line "Detaching Robot server(s) #{attached.join(", ")} from vSwitch #{vswitch.id}..."
      robot_client.remove_vswitch_servers(vswitch.id, attached)
    end

    return if config.existing_vswitch_id

    log_line "Deleting vSwitch #{vswitch.name} (#{vswitch.id})..."
    robot_client.delete_vswitch(vswitch.id)
  end

  private def wanted_server_numbers : Array(Int32)
    settings.robot_external_nodes.compact_map(&.robot_server_number)
  end

  private def find(config) : Hetzner::Robot::Client::VSwitch?
    if existing_id = config.existing_vswitch_id
      return robot_client.vswitch(existing_id)
    end

    name = config.name_for(settings.cluster_name)
    listed = robot_client.vswitches.find { |candidate| candidate.name == name }
    listed ? robot_client.vswitch(listed.id) : nil
  end

  private def find_or_create(config) : Hetzner::Robot::Client::VSwitch
    if vswitch = find(config)
      unless vswitch.vlan == config.vlan
        raise "vSwitch #{vswitch.name} (#{vswitch.id}) uses VLAN #{vswitch.vlan} but the configuration says #{config.vlan}; fix vswitch.vlan or point existing_vswitch_id elsewhere"
      end
      return vswitch
    end

    name = config.name_for(settings.cluster_name)
    log_line "Creating vSwitch #{name} (VLAN #{config.vlan})..."
    robot_client.create_vswitch(name, config.vlan)
  end

  private def all_ready?(servers) : Bool
    wanted = wanted_server_numbers
    relevant = servers.select { |server| wanted.includes?(server.number) }
    relevant.size == wanted.size && relevant.all? { |server| server.status == "ready" }
  end

  private def attach_missing(vswitch) : Bool
    missing = wanted_server_numbers - vswitch.server_numbers
    return false if missing.empty?

    log_line "Attaching Robot server(s) #{missing.join(", ")} to vSwitch #{vswitch.id}..."
    robot_client.add_vswitch_servers(vswitch.id, missing)
    true
  end

  private def wait_until_ready(id : Int32) : Nil
    wanted = wanted_server_numbers
    deadline = Time.instant + ready_timeout

    loop do
      servers = robot_client.vswitch(id).servers.select { |server| wanted.includes?(server.number) }
      failed = servers.select { |server| server.status == "failed" }
      raise "Robot reports vSwitch #{id} failed for server(s) #{failed.map(&.number).join(", ")}; check the vSwitch in Robot" unless failed.empty?

      return if servers.size == wanted.size && servers.all? { |server| server.status == "ready" }

      pending = wanted - servers.select { |server| server.status == "ready" }.map(&.number)
      raise "Timed out after #{ready_timeout.total_minutes.to_i} minutes waiting for vSwitch #{id} to be ready on server(s) #{pending.join(", ")}" if Time.instant > deadline

      log_line "Waiting for vSwitch #{id} to be ready on server(s) #{pending.join(", ")}..."
      sleep poll_interval
    end
  end

  private def default_log_prefix
    "vSwitch"
  end
end
