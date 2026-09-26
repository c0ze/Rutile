require_relative "lib/rutile/version"

Gem::Specification.new do |spec|
  spec.name = "rutile"
  spec.version = Rutile::VERSION
  spec.authors = ["Arda Karaduman"]
  spec.email = ["arda@gand.tr"]

  spec.summary = "Compiles Rails apps written in a strict subset of Ruby to Rust."
  spec.required_ruby_version = ">= 3.4"

  spec.files = Dir["lib/**/*.rb", "exe/*", "config/*.yml", "README.md"]
  spec.metadata["default_lint_roller_plugin"] = "RuboCop::Rutile::Plugin"
  spec.bindir = "exe"
  spec.executables = ["rutile"]
  spec.require_paths = ["lib"]

  # rbs-inline signatures are read with the RBS parser.
  spec.add_dependency "rbs", ">= 3.8"
end
