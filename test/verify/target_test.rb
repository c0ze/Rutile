require "minitest/autorun"
require "socket"
require "zlib"
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

  # Rails clears the test's query cache when a request writes in-process;
  # a request served elsewhere has to do it through this hook.
  def test_runs_the_after_request_hook
    server = RecordingServer.new("HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n")
    calls = 0
    target = Rutile::Verify::Target.new("http://127.0.0.1:#{server.port}") { calls += 1 }
    target.call(Rack::MockRequest.env_for("/up"))
    server.join
    assert_equal 1, calls
  end

  # Net::HTTP asks for compression on its own and inflates what comes back;
  # the forwarded request must carry only what the test sent.
  def test_sends_no_accept_encoding_the_test_did_not_send
    server = RecordingServer.new("HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n")
    Rutile::Verify::Target.new("http://127.0.0.1:#{server.port}").call(Rack::MockRequest.env_for("/up"))
    server.join
    refute_match(/^Accept-Encoding:/i, server.request)
  end

  def test_passes_a_compressed_response_through_untouched
    gzipped = Zlib.gzip("{}")
    reply = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Encoding: gzip\r\nContent-Length: #{gzipped.bytesize}\r\nConnection: close\r\n\r\n".b + gzipped
    server = RecordingServer.new(reply)
    target = Rutile::Verify::Target.new("http://127.0.0.1:#{server.port}")
    _, headers, body = target.call(Rack::MockRequest.env_for("/up", "HTTP_ACCEPT_ENCODING" => "gzip"))
    server.join
    assert_match(/^Accept-Encoding: gzip\r$/i, server.request)
    assert_equal "gzip", headers["content-encoding"]
    assert_equal gzipped, body.join.b
  end
end
