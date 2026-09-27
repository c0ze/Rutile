require "json"
require "open3"
require "tmpdir"
require "socket"
require_relative "unbundled"
require_relative "verify/servers"

module Rutile
  # `rutile verify`: the app's own integration tests, run against the Rust
  # build. The crate is built for release and started on the app's test
  # database; the tests' requests go to it through Verify::Target.
  module Verify
    class Error < StandardError; end

    HOOK = File.expand_path("verify/hook.rb", __dir__)
    # Prints the test database's URL from inside the app.
    DATABASE_URL = <<~'RUBY'.freeze
      config = ActiveRecord::Base.configurations.configs_for(env_name: "test").first.configuration_hash
      url = config[:url] || begin
        user = [config[:username], config[:password]].compact.map { ERB::Util.url_encode(_1.to_s) }.join(":")
        port = ":#{config[:port]}" if config[:port]
        "postgres://#{"#{user}@" unless user.empty?}#{config[:host] || "localhost"}#{port}/#{config[:database]}"
      end
      puts "RUTILE_DATABASE_URL=#{url}"
    RUBY

    module_function

    # True when every test passed. `tests` are paths under the app, `vars`
    # extra environment for the app's processes.
    def run(app_dir:, crate:, tests: ["test/integration"], vars: {}, out: $stdout)
      rails = File.join(app_dir, "bin/rails")
      raise Error, "no bin/rails in #{app_dir}" unless File.exist?(rails)

      binary = build(crate, out)
      env = vars.merge("RAILS_ENV" => "test")
      rails!(env, app_dir, "db:prepare")
      port = free_port
      server_env = { "DATABASE_URL" => database_url(app_dir, env), "BIND" => "127.0.0.1:#{port}", "WORKERS" => "4" }
      server = spawn(server_env, binary)
      begin
        Servers.wait_for_up("http://127.0.0.1:#{port}/up", server)
        out.puts "#{File.basename(binary)} listening on 127.0.0.1:#{port}"
        log = File.join(Dir.mktmpdir("rutile-verify"), "forwarded")
        test_env = env.merge("RUTILE_TARGET" => "http://127.0.0.1:#{port}", "PARALLEL_WORKERS" => "1", "RUTILE_VERIFY_LOG" => log,
                             "RUBYOPT" => [ENV.fetch("RUBYOPT", nil), "-r#{HOOK}"].compact.join(" "))
        passed = Rutile.unbundled { system(test_env, rails, "test", *tests, chdir: app_dir) }
        forwarded = File.exist?(log) ? File.read(log).to_i : 0
        raise Error, "the tests never reached #{File.basename(binary)}: is rails/test_help required?" if forwarded.zero?

        out.puts "#{forwarded} requests went to #{File.basename(binary)}"
        passed
      ensure
        Servers.stop_all([server])
      end
    end

    # `cargo build --release`, and the binary it made.
    def build(crate, out)
      manifest = File.join(crate, "Cargo.toml")
      raise Error, "no Cargo.toml in #{crate}; rutile build writes the crate" unless File.exist?(manifest)

      out.puts "cargo build --release --manifest-path #{manifest}"
      raise Error, "cargo build failed for #{crate}" unless system("cargo", "build", "--release", "--manifest-path", manifest)

      metadata = JSON.parse(capture!("cargo", "metadata", "--format-version", "1", "--no-deps", "--manifest-path", manifest))
      package = metadata["packages"].find { File.expand_path(_1["manifest_path"]) == File.expand_path(manifest) }
      File.join(metadata["target_directory"], "release", package.fetch("name"))
    end

    def database_url(app_dir, env)
      output = Rutile.unbundled { capture!(env, File.join(app_dir, "bin/rails"), "runner", DATABASE_URL, chdir: app_dir) }
      output[/^RUTILE_DATABASE_URL=(.+)$/, 1] or raise Error, "couldn't read the test database's URL from #{app_dir}"
    end

    def rails!(env, app_dir, *args)
      ok = Rutile.unbundled { system(env, File.join(app_dir, "bin/rails"), *args, chdir: app_dir) }
      raise Error, "bin/rails #{args.join(" ")} failed in #{app_dir}" unless ok
    end

    def capture!(*command, **options)
      output, status = Open3.capture2(*command, **options)
      raise Error, "#{command.grep(String).first(3).join(" ")} failed" unless status.success?

      output
    end

    def free_port
      server = TCPServer.new("127.0.0.1", 0)
      server.addr[1]
    ensure
      server&.close
    end
  end
end
