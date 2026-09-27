require "net/http"
require "open3"
require_relative "../lib/rutile/unbundled"
require_relative "../lib/rutile/verify"

# Rails (Puma) and the Rust port on the same database and rows, measured
# with RustOnRails' `loadgen`: requests per second, p50/p99 latency, and
# memory. Before anything is measured, every endpoint must give the same
# status and body on both servers.
#
#   EXAMPLE=blog|tracker|store  the app (blog by default)
#   RAILS_WORKERS=N       Puma in cluster mode, N processes (default: one process)
#   RAILS_YJIT=0          Rails on the interpreter (default: YJIT, which Rails 7.2+ turns on)
#   RUNS=N                measured runs per endpoint and server (default 1)
namespace :example do
  desc "Benchmark the example app on Rails and on the Rust port"
  task benchmark: :build do
    rust = RUST_DIR
    Dir.chdir(rust) { sh "cargo", "build", "--release", "-p", EXAMPLE, "-p", "loadgen" }
    loadgen = Rutile::Verify::Servers.release_binary(rust, "loadgen")
    bench = BENCHMARKS.fetch(EXAMPLE) { abort "no benchmark for EXAMPLE=#{EXAMPLE}" }
    load_rows(bench[:seed])
    paths = bench[:paths].call
    [54410, 54420].each { Rutile::Verify::Servers.ensure_port_free(_1) }
    rails = start_rails(54410, threads: 5, workers: ENV.fetch("RAILS_WORKERS", "0").to_i)
    rust_server = start_rust(rust, 54420, workers: 5)
    servers = [["rails", 54410, rails], ["rust", 54420, rust_server]]
    servers.each { |_, port, pid| Rutile::Verify::Servers.wait_for_up("http://127.0.0.1:#{port}/up", pid, timeout: 60) }
    # Per path: the app's headers, what it accepts, and anything its setup
    # made (the store's session cookie, which Rails writes).
    extra = bench[:session]&.call || {}
    headers_for = lambda do |path|
      [*bench[:headers], "Accept: #{bench[:accept]&.call(path) || "application/json"}", *extra[path]]
    end
    same_responses!(paths, headers_for)
    puts "rails: #{rails_setup}; rust: 5 workers; loadgen: 10 connections, 3 s warm-up, 10 s per run"
    servers.each do |name, port, pid|
      paths.each do |path|
        url = "http://127.0.0.1:#{port}#{path}"
        headers = headers_for.(path)
        system(loadgen, url, "10", "3", *headers, out: File::NULL, exception: true) # warm up
        ENV.fetch("RUNS", "1").to_i.times do
          result = capture!(loadgen, url, "10", "10", *headers)
          puts format("%-5s %-26s %s  memory %d MiB", name, bench[:label].(path), result, memory_mib(pid))
        end
      end
    end
  ensure
    Rutile::Verify::Servers.stop_all([rails, rust_server])
  end
end

# What each example is measured on: the rows it loads, the endpoints, and
# the headers every request carries.
BENCHMARKS = {
  "blog" => {
    seed: 'user = User.first; 100.times { |i| Post.create!(user:, title: "Post #{i}", body: "Body #{i}", status: :published) }',
    paths: -> { ["/posts", "/posts/#{first_id("posts")}"] },
    label: ->(path) { path.sub(/\d+\z/, ":id") },
    headers: []
  },
  # Alice's projects: 20 of 42 on a page. "Big" holds 50 tasks with due
  # dates around today, so `overdue` varies.
  "tracker" => {
    seed: <<~'RUBY',
      alice = User.find_by!(email: "alice@example.com")
      bob = User.find_by!(email: "bob@example.com")
      40.times { |i| Project.create!(name: format("Project %02d", i), owner: alice) }
      big = Project.create!(name: "Big", owner: alice)
      big.memberships.create!(user: bob, role: :member)
      50.times do |i|
        big.tasks.create!(title: "Task #{i}", notes: "Notes #{i}", status: %i[todo doing done][i % 3],
                          priority: %i[low normal high][i % 3], estimate: i + 1, due_on: Date.current + (i - 25),
                          assignee: i.even? ? bob : alice)
      end
    RUBY
    paths: lambda do
      big = sql("SELECT id FROM projects WHERE name = 'Big'")
      ["/projects", "/projects/#{big}", "/projects/#{big}/tasks", "/tasks/#{sql("SELECT min(id) FROM tasks WHERE project_id = #{big}")}"]
    end,
    label: ->(path) { path.gsub(/\d+/, ":id") },
    headers: ["X-Api-Token: alice-token-0000000000000"]
  },
  # 40 more products than the fixtures, JSON and HTML: the list, one
  # product, SQL aggregates, the storefront's ERB pages (with a layout and
  # related products), and the cart the session cookie holds.
  "store" => {
    seed: <<~'RUBY',
      40.times { |i| Product.create!(name: format("Item %02d", i), price_cents: 500 + i * 25, stock: i % 7, active: i % 9 != 0) }
    RUBY
    paths: lambda do
      id = sql("SELECT min(id) FROM products WHERE active AND stock > 0")
      ["/products", "/products/#{id}", "/products/stats", "/shop", "/shop/#{id}", "/cart"]
    end,
    label: ->(path) { path.gsub(/\d+/, ":id") },
    headers: [],
    # The storefront answers HTML; the API, JSON.
    accept: ->(path) { path.start_with?("/shop") ? "text/html" : "application/json" },
    # A cart Rails put in its encrypted session cookie, which both servers
    # then decrypt on every /cart request (they share the secret).
    session: lambda do
      id = sql("SELECT min(id) FROM products WHERE active AND stock > 0")
      response = Net::HTTP.start("127.0.0.1", 54410) do |http|
        http.post("/cart/add", "product_id=#{id}&quantity=2&shopper=ann", "Accept" => "application/json")
      end
      abort "POST /cart/add answered #{response.code}" unless response.code == "200"
      cookies = response.get_fields("set-cookie").map { _1.split(";").first }
      { "/cart" => ["Cookie: #{cookies.join("; ")}"] }
    end
  }
}.freeze

# The fixtures, then the benchmark's rows, in the database both servers use.
def load_rows(script)
  Dir.chdir(EXAMPLE_APP) do
    Rutile.unbundled do
      sh(EXAMPLE_ENV, "bin/rails", "db:fixtures:load")
      sh(EXAMPLE_ENV, "bin/rails", "runner", script)
    end
  end
end

def sql(query) = capture!("psql", "-h", "localhost", "-p", PG_PORT, "-U", "postgres", "-d", "#{EXAMPLE}_test", "-Atc", query)

# What the command printed, stripped; it failing fails the benchmark.
def capture!(*command)
  out, status = Open3.capture2(*command)
  abort "#{command.first} failed (#{status})" unless status.success?
  out.strip
end

def first_id(table) = sql("SELECT id FROM #{table} ORDER BY id LIMIT 1")

# A benchmark compares like with like only if both servers answer alike.
def same_responses!(paths, headers_for)
  paths.each do |path|
    fields = headers_for.(path).to_h { _1.split(":", 2).map(&:strip) }
    rails, rust = [54410, 54420].map do |port|
      response = Net::HTTP.start("127.0.0.1", port) { |http| http.get(path, fields) }
      [response.code, response.body]
    end
    abort "#{path}: Rails answered #{rails.first}, Rust #{rust.first}" unless rails.first == rust.first
    abort "#{path}: the bodies differ\nrails: #{rails.last[0, 500]}\nrust:  #{rust.last[0, 500]}" unless rails.last == rust.last
    puts "#{path}: #{rails.first}, #{rails.last.bytesize} bytes, the same from both"
  end
end

def rails_workers = ENV.fetch("RAILS_WORKERS", "0").to_i
def rails_yjit? = ENV.fetch("RAILS_YJIT", "1") == "1"

def rails_setup
  processes = rails_workers.positive? ? "Puma cluster, #{rails_workers} workers x 5 threads" : "one Puma process, 5 threads"
  "#{processes}, #{rails_yjit? ? "YJIT" : "interpreter"}"
end

def start_rails(port, threads:, workers:)
  env = EXAMPLE_ENV.merge("RAILS_ENV" => "benchmark", "SECRET_KEY_BASE" => "benchmark", "RAILS_MAX_THREADS" => threads.to_s,
                          "PORT" => port.to_s, "RAILS_YJIT" => rails_yjit? ? "1" : "0")
  # macOS's Objective-C runtime aborts a forked Puma worker unless told not to.
  env["OBJC_DISABLE_INITIALIZE_FORK_SAFETY"] = "YES" if RUBY_PLATFORM.include?("darwin")
  command = ["bundle", "exec", "puma", "-C", "config/puma.rb", "-e", "benchmark", "-p", port.to_s]
  command += ["-w", workers.to_s] if workers.positive?
  Dir.chdir(EXAMPLE_APP) { Rutile.unbundled { spawn(env, *command, out: File::NULL) } }
end

def start_rust(rust, port, workers:)
  # The same secret as Rails', so either reads the other's session cookie.
  env = { "DATABASE_URL" => "postgres://postgres@localhost:#{PG_PORT}/#{EXAMPLE}_test", "BIND" => "127.0.0.1:#{port}",
          "WORKERS" => workers.to_s, "SECRET_KEY_BASE" => "benchmark", "REDIS_URL" => EXAMPLE_ENV["REDIS_URL"] }
  spawn(env, Rutile::Verify::Servers.release_binary(rust, EXAMPLE), err: File::NULL)
end

# The server and its forked workers. Proportional set size where Linux
# reports it, so pages Puma's workers share count once; RSS elsewhere.
def memory_mib(pid)
  pids = [pid, *`pgrep -P #{pid}`.split.map(&:to_i)]
  kib = pids.sum do |p|
    rollup = "/proc/#{p}/smaps_rollup"
    File.exist?(rollup) ? File.read(rollup)[/^Pss:\s+(\d+)/, 1].to_i : `ps -o rss= -p #{p}`.to_i
  end
  kib / 1024
end
