require_relative "../lib/rutile/unbundled"
require_relative "support/servers"

# Rails (Puma) and the Rust port on the same database and rows, measured
# with RustOnRails' `loadgen`: requests per second, p50/p99 latency, and
# resident memory.
namespace :example do
  desc "Benchmark the example app on Rails and on the Rust port"
  task benchmark: :build do
    blog_only!
    rust = File.expand_path(ENV.fetch("RUSTONRAILS_DIR", "../../RustOnRails"), __dir__)
    Dir.chdir(rust) { sh "cargo", "build", "--release", "-p", "blog", "-p", "loadgen" }
    loadgen = File.join(rust, "target/release/loadgen")
    seed_posts
    [54410, 54420].each { ExampleServers.ensure_port_free(_1) }
    rails = start_rails(54410, threads: 5)
    rust_server = start_rust(rust, 54420, workers: 5)
    [["rails", 54410, rails], ["rust", 54420, rust_server]].each do |name, port, pid|
      ExampleServers.wait_for_up("http://127.0.0.1:#{port}/up", pid)
      id = first_post_id
      ["/posts", "/posts/#{id}"].each do |path|
        url = "http://127.0.0.1:#{port}#{path}"
        sh loadgen, url, "10", "3", out: File::NULL # warm up
        puts format("%-5s %-12s %s  rss %d MiB", name, path, `#{loadgen} #{url} 10 10`.strip, rss_mib(pid))
      end
    end
  ensure
    ExampleServers.stop_all([rails, rust_server])
  end
end

def seed_posts
  script = 'user = User.first; 100.times { |i| Post.create!(user:, title: "Post #{i}", body: "Body #{i}", status: :published) }'
  Dir.chdir(EXAMPLE_APP) do
    Rutile.unbundled do
      sh(EXAMPLE_ENV, "bin/rails", "db:fixtures:load")
      sh(EXAMPLE_ENV, "bin/rails", "runner", script)
    end
  end
end

def start_rails(port, threads:)
  env = EXAMPLE_ENV.merge("RAILS_ENV" => "benchmark", "SECRET_KEY_BASE" => "benchmark", "RAILS_MAX_THREADS" => threads.to_s)
  Dir.chdir(EXAMPLE_APP) { Rutile.unbundled { spawn(env, "bin/rails", "server", "-p", port.to_s, out: File::NULL) } }
end

def start_rust(rust, port, workers:)
  env = { "DATABASE_URL" => "postgres://postgres@localhost:#{PG_PORT}/blog_test", "BIND" => "127.0.0.1:#{port}", "WORKERS" => workers.to_s }
  spawn(env, File.join(rust, "target/release/blog"), err: File::NULL)
end

def first_post_id
  `psql -h localhost -p #{PG_PORT} -U postgres -d blog_test -Atc "SELECT id FROM posts ORDER BY id LIMIT 1"`.to_i
end

def rss_mib(pid)
  `ps -o rss= -p #{pid}`.to_i / 1024
end
