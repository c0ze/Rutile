require "minitest/autorun"
require "socket"
require_relative "../rakelib/support/servers"

# The example tasks must test the server they just started, not whatever
# already answers on the port.
class ServersTest < Minitest::Test
  def test_refuses_a_port_something_already_listens_on
    listener = TCPServer.new("127.0.0.1", 0)
    error = assert_raises(RuntimeError) { ExampleServers.ensure_port_free(listener.addr[1]) }
    assert_match(/already in use/, error.message)
  ensure
    listener&.close
  end

  def test_stops_waiting_when_the_server_exits
    pid = spawn("ruby", "-e", "exit 3")
    started = Time.now
    error = assert_raises(RuntimeError) { ExampleServers.wait_for_up("http://127.0.0.1:1/up", pid) }
    assert_match(/exited/, error.message)
    assert_operator Time.now - started, :<, 5
    ExampleServers.stop_all([pid])
  end

  def test_only_a_200_counts_as_up
    listener = TCPServer.new("127.0.0.1", 0)
    answers = ["503 Service Unavailable", "200 OK"]
    responder = Thread.new do
      answers.each do |status|
        client = listener.accept
        client.gets("\r\n\r\n")
        client.write("HTTP/1.1 #{status}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        client.close
      end
    end
    pid = spawn("sleep", "30")
    ExampleServers.wait_for_up("http://127.0.0.1:#{listener.addr[1]}/up", pid)
    # Both answers were used: the 503 didn't count.
    assert responder.join(2)
    ExampleServers.stop_all([pid])
  ensure
    listener&.close
  end

  def test_a_server_that_died_during_the_run_fails_the_stop
    pid = spawn("ruby", "-e", "exit 1")
    sleep 0.5
    error = assert_raises(RuntimeError) { ExampleServers.stop_all([pid]) }
    assert_match(/died/, error.message)
  end
end
