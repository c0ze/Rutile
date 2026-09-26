require "json"
require "net/http"
require "socket"

# Starting and stopping the servers the example tasks run against, making
# sure the server that answers is the one just started.
module ExampleServers
  module_function

  # Where `cargo build --release` in `workspace` put `name`: its target
  # directory follows CARGO_TARGET_DIR and .cargo/config, not always target/.
  def release_binary(workspace, name)
    metadata = IO.popen(%w[cargo metadata --format-version 1 --no-deps], chdir: workspace, &:read)
    raise "cargo metadata failed in #{workspace}" unless $?.success?

    File.join(JSON.parse(metadata).fetch("target_directory"), "release", name)
  end

  def ensure_port_free(port)
    TCPSocket.new("127.0.0.1", port).close
  rescue SystemCallError
    nil
  else
    raise "port #{port} is already in use; stop whatever is listening there first"
  end

  # Polls `url` until it answers 200, for up to `timeout` seconds. `pid` is
  # the server just started; if it exits first, there's nothing to wait for.
  def wait_for_up(url, pid, timeout: 30)
    deadline = Time.now + timeout
    loop do
      raise "the server for #{url} exited (#{$?}) before answering" if Process.waitpid(pid, Process::WNOHANG)
      return if up?(url)
      raise "#{url} didn't come up" if Time.now > deadline

      sleep 0.2
    end
  end

  def up?(url)
    uri = URI(url)
    Net::HTTP.start(uri.host, uri.port, open_timeout: 2, read_timeout: 2) { |http| http.get(uri.path).code == "200" }
  rescue SystemCallError, IOError, Net::OpenTimeout, Net::ReadTimeout
    false
  end

  # Stops every server, then fails if any of them had died on its own.
  def stop_all(pids)
    errors = pids.compact.filter_map do |pid|
      stop(pid)
      nil
    rescue RuntimeError => e
      e
    end
    raise errors.first if errors.any?
  end

  def stop(pid)
    exited = Process.waitpid(pid, Process::WNOHANG)
  rescue Errno::ECHILD
    nil # already reaped by wait_for_up
  else
    raise "server #{pid} died during the run (#{$?})" if exited

    Process.kill("TERM", pid)
    Process.wait(pid)
  end
end
