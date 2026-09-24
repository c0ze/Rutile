# Loaded by `bin/rails runner` inside the target app (see Rutile::Introspect.run).
# It may use only Ruby's standard library and Rails: the app's Gemfile doesn't
# include Rutile, and nothing outside this directory is loaded here.
require "json"
require_relative "manifest"

if ActiveRecord::Base.descendants.any? { Rutile::Introspect::Source.app_defined?(_1) }
  abort "rutile: app models were loaded before introspection started, so their scopes can't be recorded. " \
        "Run introspection with config.eager_load off (development, or test without CI set)."
end

Rutile::Introspect::ScopeRecorder.install!
Rails.application.eager_load!
manifest = Rutile::Introspect::Manifest.build(Rails.application)
File.write(ENV.fetch("RUTILE_MANIFEST_OUT"), JSON.pretty_generate(manifest) + "\n")
