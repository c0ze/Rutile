require "minitest/autorun"
require "socket"
require "rack"
require_relative "../../lib/rutile/verify/target"

# A one-request HTTP server on a thread: records what arrived and answers
# with a fixed response.
class RecordingServer
  attr_reader :port, :request

  def initialize(response)
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
    @thread = Thread.new do
      client = @server.accept
      head = +""
      head << client.gets until head.end_with?("\r\n\r\n")
      length = head[/Content-Length: (\d+)/i, 1].to_i
      @request = head + client.read(length).to_s
      client.write(response)
      client.close
    end
  end

  def join = @thread.join
end

class TargetTest < Minitest::Test
  def test_forwards_method_path_body_and_content_type
    reply = "HTTP/1.1 422 Unprocessable Content\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}"
    server = RecordingServer.new(reply)
    target = Rutile::Verify::Target.new("http://127.0.0.1:#{server.port}")
    env = Rack::MockRequest.env_for("/posts/5?x=1", method: "PATCH", input: '{"title":"A"}', "CONTENT_TYPE" => "application/json")

    status, headers, body = target.call(env)
    server.join

    assert_match(%r{\APATCH /posts/5\?x=1 HTTP/1.1\r\n}, server.request)
    assert_match(%r{^Content-Type: application/json\r$}i, server.request)
    assert server.request.end_with?('{"title":"A"}')
    assert_equal 422, status
    assert_equal "application/json; charset=utf-8", headers["content-type"]
    assert_equal ["{}"], body
  end
end
