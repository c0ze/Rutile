require "json"
require_relative "check/rules"
require_relative "check/gems"
require_relative "check/files"

module Rutile
  # `rutile check`: everything `rutile build` would refuse, found in one
  # pass: the design's source rules, the build itself with every failing
  # unit recorded instead of fatal, the app's gems, and app files Rutile
  # doesn't compile.
  module Check
    module_function

    def run(app_dir:, manifest: nil, env: "development", vars: {})
      manifest ||= Introspect.run(app_dir:, env:, out: File.join(app_dir, "tmp/rutile/manifest.json"), vars:)
      diagnostics = Build::Diagnostics.new
      app = Build::App.new(app_dir, JSON.parse(File.read(manifest)), diagnostics:)
      Rules.scan(app_dir, diagnostics)
      Gems.check(app.manifest, diagnostics)
      Files.check(app_dir, diagnostics)
      Build::Crate.new(app, app_dir, name: File.basename(app_dir), runtime: app_dir).files
      diagnostics
    end

    # Problems, then notes, then the count.
    def report(diagnostics)
      problems = diagnostics.problems
      notes = diagnostics.notes
      summary = problems.empty? ? "no problems" : count(problems.size, "problem")
      summary += ", #{count(notes.size, "note")}" unless notes.empty?
      [*problems, *notes.map { "note: #{_1}" }, summary].join("\n")
    end

    def count(n, noun) = "#{n} #{noun}#{"s" unless n == 1}"
  end
end
