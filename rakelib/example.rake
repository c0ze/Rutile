require_relative "../lib/rutile/unbundled"
require_relative "support/servers"

# A throwaway Postgres cluster under tmp/pg for the example app, using the
# PostgreSQL that mise.toml pins. It never touches a system server.
PG_DIR = File.expand_path("../tmp/pg", __dir__)
PG_PORT = ENV.fetch("BLOG_DB_PORT", "54329")
EXAMPLE_APP = File.expand_path("../examples/blog", __dir__)
# Connection URLs exported for another project would override database.yml
# and point db:prepare and fixture loading at that project's database.
EXAMPLE_ENV = { "RAILS_ENV" => "test", "DATABASE_URL" => nil, "PRIMARY_DATABASE_URL" => nil }.freeze

def pg_running?
  system("pg_ctl", "-D", PG_DIR, "status", out: File::NULL, err: File::NULL)
end

namespace :pg do
  desc "Start the local Postgres cluster, creating it on first use"
  task :start do
    unless File.exist?(File.join(PG_DIR, "PG_VERSION"))
      sh "initdb", "-D", PG_DIR, "-U", "postgres", "--auth=trust", "--encoding=UTF8", "--no-locale"
    end
    next if pg_running?

    sh "pg_ctl", "-D", PG_DIR, "-l", File.join(PG_DIR, "server.log"), "-w",
       "-o", "-p #{PG_PORT} -k #{PG_DIR} -c listen_addresses=localhost", "start"
  end

  desc "Stop the local Postgres cluster"
  task :stop do
    sh "pg_ctl", "-D", PG_DIR, "-m", "fast", "stop" if pg_running?
  end
end

namespace :example do
  desc "Create and migrate the example app's test database"
  task db: "pg:start" do
    Dir.chdir(EXAMPLE_APP) do
      Rutile.unbundled { sh(EXAMPLE_ENV, "bin/rails", "db:prepare") }
    end
  end

  desc "Check the example app for anything rutile build can't compile"
  task check: :db do
    require_relative "../lib/rutile"
    clean = { "CI" => nil, "DATABASE_URL" => nil, "PRIMARY_DATABASE_URL" => nil }
    diagnostics = Rutile::Check.run(app_dir: EXAMPLE_APP, env: "test", vars: clean)
    puts Rutile::Check.report(diagnostics)
    abort unless diagnostics.problems.empty?
  end

  desc "Generate the example app's Rust crate into RustOnRails/examples/blog"
  task build: :db do
    require_relative "../lib/rutile"
    rust = File.expand_path(ENV.fetch("RUSTONRAILS_DIR", "../../RustOnRails"), __dir__)
    clean = { "CI" => nil, "DATABASE_URL" => nil, "PRIMARY_DATABASE_URL" => nil }
    Rutile::Build.run(app_dir: EXAMPLE_APP, out: File.join(rust, "examples/blog"), runtime: rust, name: "blog",
                      env: "test", vars: clean)
    puts "generated #{File.join(rust, "examples/blog/src")}"
  end

  desc "Run the example app's integration tests against the Rust port"
  task verify: :build do
    rust = File.expand_path(ENV.fetch("RUSTONRAILS_DIR", "../../RustOnRails"), __dir__)
    port = ENV.fetch("VERIFY_PORT", "54400")
    Dir.chdir(rust) { sh "cargo", "build", "--release", "-p", "blog" }
    env = { "DATABASE_URL" => "postgres://postgres@localhost:#{PG_PORT}/blog_test", "BIND" => "127.0.0.1:#{port}", "WORKERS" => "4" }
    ExampleServers.ensure_port_free(port)
    server = spawn(env, File.join(rust, "target/release/blog"))
    begin
      ExampleServers.wait_for_up("http://127.0.0.1:#{port}/up", server)
      target = { "RUTILE_TARGET" => "http://127.0.0.1:#{port}", "PARALLEL_WORKERS" => "1" }
      Dir.chdir(EXAMPLE_APP) { Rutile.unbundled { sh(EXAMPLE_ENV.merge(target), "bin/rails", "test", "test/integration") } }
    ensure
      ExampleServers.stop_all([server])
    end
  end

  desc "Run the example app's own test suite"
  task test: :db do
    Dir.chdir(EXAMPLE_APP) { Rutile.unbundled { sh(EXAMPLE_ENV, "bin/rails", "test") } }
  end
end
