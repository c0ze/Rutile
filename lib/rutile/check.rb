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
      app = Build::App.new(app_dir, Build.read_manifest(manifest), diagnostics:)
      source(app_dir, app, diagnostics)
      Files.check(app_dir, diagnostics)
      Build::Crate.new(app, app_dir, name: File.basename(app_dir), runtime: app_dir).files
      app.fallbacks.each { diagnostics.note(_1) }
      diagnostics
    end

    # What no translation can see: the design's source rules over app/,
    # lib/ and the initializers, and gems that change Rails at runtime.
    def source(app_dir, app, diagnostics)
      Rules.scan(app_dir, diagnostics, homes: homes(app))
      Gems.check(app.manifest, diagnostics)
    end

    # rutile build's gate: every such problem, before anything is written.
    def source!(app_dir, app)
      diagnostics = Build::Diagnostics.new
      source(app_dir, app, diagnostics)
      raise Build::Unsupported, diagnostics.problems.join("\n") unless diagnostics.problems.empty?
    end

    # Each app model, controller and job's own file. ApplicationRecord is
    # abstract, so the manifest's models leave it out, and ApplicationJob
    # performs nothing; a patch to either changes every class under it.
    def homes(app)
      found = (app.models + app.controllers + (app.manifest.dig("jobs", "classes") || [])).to_h { [_1["name"], _1.dig("source", "path")] }.compact
      found["ApplicationRecord"] ||= Build::Constants::PARENTS.fetch(:model)
      found["ApplicationJob"] ||= "app/jobs/application_job.rb"
      found
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
