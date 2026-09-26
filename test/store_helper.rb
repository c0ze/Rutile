require_relative "introspect_helper"
require_relative "../lib/rutile/build"

# The store example as `rutile build` sees it, introspected once per test
# process. Its database comes from `rake example:db EXAMPLE=store`.
module StoreHelper
  APP = File.expand_path("../examples/store", __dir__)

  def self.manifest
    @manifest ||= begin
      out = File.join(Dir.mktmpdir("rutile"), "manifest.json")
      Rutile::Introspect.run(app_dir: APP, env: "test", out:, vars: IntrospectHelper::CLEAN_ENV)
      JSON.parse(File.read(out))
    end
  end

  # A fresh app with its own collector, so each test sees only its findings.
  def store = Rutile::Build::App.new(APP, StoreHelper.manifest, diagnostics: Rutile::Build::Diagnostics.new)
end
