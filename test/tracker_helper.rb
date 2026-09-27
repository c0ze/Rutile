require_relative "introspect_helper"
require_relative "../lib/rutile/build"

# The tracker example as `rutile build` sees it, introspected once per test
# process. Its database comes from `rake example:db EXAMPLE=tracker`.
module TrackerHelper
  APP = File.expand_path("../examples/tracker", __dir__)

  def self.manifest
    @manifest ||= begin
      out = File.join(Dir.mktmpdir("rutile"), "manifest.json")
      Rutile::Introspect.run(app_dir: APP, env: "test", out:, vars: IntrospectHelper::CLEAN_ENV)
      JSON.parse(File.read(out, encoding: Encoding::UTF_8))
    end
  end

  # A fresh app with its own collector, so each test sees only its findings.
  def tracker = Rutile::Build::App.new(APP, TrackerHelper.manifest, diagnostics: Rutile::Build::Diagnostics.new)
end
