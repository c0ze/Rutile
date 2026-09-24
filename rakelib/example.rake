require_relative "../lib/rutile/unbundled"

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

  desc "Run the example app's own test suite"
  task test: :db do
    Dir.chdir(EXAMPLE_APP) { Rutile.unbundled { sh(EXAMPLE_ENV, "bin/rails", "test") } }
  end
end
