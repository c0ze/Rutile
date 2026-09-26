require "minitest/autorun"
require "json"
require "tmpdir"
require_relative "../lib/rutile"

# Runs `rutile introspect` against examples/blog once per test process and
# shares the result. Needs the example database; `bundle exec rake test`
# starts Postgres and prepares it first.
module IntrospectHelper
  APP = File.expand_path("../examples/blog", __dir__)
  # CI=1 turns on eager loading in the test env, which introspection refuses;
  # exported connection URLs would take the app off the example cluster.
  CLEAN_ENV = { "CI" => nil, "DATABASE_URL" => nil, "PRIMARY_DATABASE_URL" => nil }.freeze

  def self.manifest_text
    @manifest_text ||= begin
      out = File.join(Dir.mktmpdir("rutile"), "manifest.json")
      Rutile::Introspect.run(app_dir: APP, env: "test", out: out, vars: CLEAN_ENV)
      File.read(out, encoding: Encoding::UTF_8)
    end
  end

  def self.manifest
    @manifest ||= JSON.parse(manifest_text)
  end

  def manifest = IntrospectHelper.manifest

  def controller(name)
    manifest.fetch("controllers").find { _1["name"] == name } || flunk("no controller #{name}")
  end

  def model(name)
    manifest.fetch("models").find { _1["name"] == name } || flunk("no model #{name}")
  end

  def table(name)
    manifest.fetch("tables").find { _1["name"] == name } || flunk("no table #{name}")
  end

  def column(table, name)
    table.fetch("columns").find { _1["name"] == name } || flunk("no column #{name}")
  end
end
