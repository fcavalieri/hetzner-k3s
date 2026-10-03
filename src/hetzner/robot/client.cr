require "base64"
require "crest"
require "json"
require "retriable"

class Hetzner::Robot::Client
  class Error < Exception
  end

  class Server
    getter number : Int32
    getter name : String
    getter ip : String

    def initialize(@number, @name, @ip)
    end
  end

  class VSwitchServer
    getter number : Int32
    getter status : String

    def initialize(@number, @status)
    end
  end

  class VSwitch
    getter id : Int32
    getter name : String
    getter vlan : Int32
    getter servers : Array(VSwitchServer)
    # A cancelled vSwitch stays listed until Robot removes it; it is no longer usable.
    getter cancelled : Bool

    def initialize(@id, @name, @vlan, @servers, @cancelled = false)
    end

    def server_numbers : Array(Int32)
      servers.map(&.number)
    end
  end

  def self.servers_form_body(server_numbers : Array(Int32)) : String
    server_numbers.map { |number| "server[]=#{number}" }.join("&")
  end

  private getter api_url : String = "https://robot-ws.your-server.de"
  private getter username : String
  private getter password : String
  private getter connect_timeout : Time::Span = 10.seconds
  private getter read_timeout : Time::Span = 30.seconds
  private getter write_timeout : Time::Span = 30.seconds

  def initialize(@username : String, @password : String)
  end

  def server(server_number : Int32) : Server
    success, response = get("/server/#{server_number}")
    raise Error.new("Failed to fetch Robot server #{server_number}: #{response.strip}") unless success

    parse_server(response)
  end

  def update_server_name(server_number : Int32, server_name : String) : Server
    success, response = post("/server/#{server_number}", {"server_name" => server_name})
    raise Error.new("Failed to update Robot server #{server_number} name: #{response.strip}") unless success

    parse_server(response)
  end

  def vswitches : Array(VSwitch)
    success, response = get("/vswitch")
    raise Error.new("Failed to list Robot vSwitches: #{response.strip}") unless success

    JSON.parse(response).as_a.map { |item| parse_vswitch(item) }
  rescue ex : JSON::ParseException | KeyError | TypeCastError
    raise Error.new("Robot vSwitch list could not be parsed: #{ex.message}")
  end

  def vswitch(id : Int32) : VSwitch
    success, response = get("/vswitch/#{id}")
    raise Error.new("Failed to fetch Robot vSwitch #{id}: #{response.strip}") unless success

    parse_vswitch(JSON.parse(response))
  rescue ex : JSON::ParseException | KeyError | TypeCastError
    raise Error.new("Robot vSwitch #{id} response could not be parsed: #{ex.message}")
  end

  def create_vswitch(name : String, vlan : Int32) : VSwitch
    success, response = post("/vswitch", {"name" => name, "vlan" => vlan.to_s})
    raise Error.new("Failed to create Robot vSwitch #{name} (VLAN #{vlan}): #{response.strip}") unless success

    parse_vswitch(JSON.parse(response))
  rescue ex : JSON::ParseException | KeyError | TypeCastError
    raise Error.new("Robot vSwitch create response could not be parsed: #{ex.message}")
  end

  def add_vswitch_servers(id : Int32, server_numbers : Array(Int32)) : Nil
    success, response = post_form("/vswitch/#{id}/server", self.class.servers_form_body(server_numbers))
    raise Error.new("Failed to add server(s) #{server_numbers.join(", ")} to Robot vSwitch #{id}: #{response.strip}") unless success
  end

  def remove_vswitch_servers(id : Int32, server_numbers : Array(Int32)) : Nil
    success, response = delete_form("/vswitch/#{id}/server", self.class.servers_form_body(server_numbers))
    raise Error.new("Failed to remove server(s) #{server_numbers.join(", ")} from Robot vSwitch #{id}: #{response.strip}") unless success
  end

  # Robot cancels a vSwitch rather than deleting it and requires the cancellation date.
  def delete_vswitch(id : Int32) : Nil
    success, response = delete_form("/vswitch/#{id}", "cancellation_date=now")
    raise Error.new("Failed to delete Robot vSwitch #{id}: #{response.strip}") unless success
  end

  private def get(path)
    response = with_network_retry do
      Crest.get(
        "#{api_url}#{path}",
        headers: headers,
        handle_errors: false,
        connect_timeout: connect_timeout,
        read_timeout: read_timeout,
        write_timeout: write_timeout
      )
    end

    handle_response(response)
  end

  private def post(path, params)
    response = with_network_retry do
      Crest.post(
        "#{api_url}#{path}",
        params,
        headers: headers,
        handle_errors: false,
        connect_timeout: connect_timeout,
        read_timeout: read_timeout,
        write_timeout: write_timeout
      )
    end

    handle_response(response)
  end

  # Raw application/x-www-form-urlencoded body: Robot's array parameters (server[]=...)
  # need the literal brackets, which Crest's Hash encoder does not produce.
  private def post_form(path, body : String)
    response = with_network_retry do
      Crest::Request.new(:post, "#{api_url}#{path}",
        form: body,
        headers: headers.merge({"Content-Type" => "application/x-www-form-urlencoded"}),
        handle_errors: false,
        connect_timeout: connect_timeout,
        read_timeout: read_timeout,
        write_timeout: write_timeout
      ).execute
    end

    handle_response(response)
  end

  private def delete_form(path, body : String)
    response = with_network_retry do
      Crest::Request.new(:delete, "#{api_url}#{path}",
        form: body,
        headers: headers.merge({"Content-Type" => "application/x-www-form-urlencoded"}),
        handle_errors: false,
        connect_timeout: connect_timeout,
        read_timeout: read_timeout,
        write_timeout: write_timeout
      ).execute
    end

    handle_response(response)
  end

  private def parse_vswitch(json : JSON::Any) : VSwitch
    object = json["vswitch"]? || json
    servers = (object["server"]?.try(&.as_a) || [] of JSON::Any).map do |server|
      VSwitchServer.new(server["server_number"].as_i, server["status"]?.try(&.as_s) || "ready")
    end
    VSwitch.new(object["id"].as_i, object["name"].as_s, object["vlan"].as_i, servers, object["cancelled"]?.try(&.as_bool?) || false)
  end

  private def headers
    {
      "Authorization" => "Basic #{Base64.strict_encode("#{username}:#{password}")}",
    }
  end

  private def with_network_retry
    Retriable.retry(
      max_attempts: 3,
      backoff: false,
      base_interval: 2.seconds,
      on: {IO::Error, Socket::Error, IO::TimeoutError}
    ) do
      yield
    end
  end

  private def handle_response(response) : Tuple(Bool, String)
    {response.success?, response.body.to_s}
  end

  private def parse_server(response : String) : Server
    server = JSON.parse(response)["server"]
    Server.new(
      server["server_number"].as_i,
      server["server_name"].as_s,
      server["server_ip"].as_s
    )
  rescue ex
    raise Error.new("Robot server response could not be parsed: #{ex.message}")
  end
end
