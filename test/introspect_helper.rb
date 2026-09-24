require "minitest/autorun"
require "json"
require "tmpdir"
require_relative "../lib/rutile"

# Runs `rutile introspect` against examples/blog once per test process and
# shares the result. Needs the example database; `bundle exec rake test`
# starts Postgres and prepares it first.
module IntrospectHelper
  APP = File.expand_path("../examples/blog", __dir__)

  def self.manifest_text
    @manifest_text ||= begin
      out = File.join(Dir.mktmpdir("rutile"), "manifest.json")
      Rutile::Introspect.run(app_dir: APP, env: "test", out: out)
      File.read(out)
    end
  end

  def self.manifest
    @manifest ||= JSON.parse(manifest_text)
  end

  def manifest = IntrospectHelper.manifest
end
