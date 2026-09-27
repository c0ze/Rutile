require_relative "lib/rutile/version"

Gem::Specification.new do |spec|
  spec.name = "rutile"
  spec.version = Rutile::VERSION
  spec.authors = ["Arda Karaduman"]
  spec.email = ["arda@gand.tr"]

  spec.summary = "Compiles Rails apps written in a strict subset of Ruby to Rust."
  spec.description = "Rutile compiles a Rails app's models, controllers, routes, sessions, jobs and ERB views into a Rust " \
                     "crate that runs on RustOnRails, refusing whatever it can't compile to the same behavior."
  spec.homepage = "https://github.com/c0ze/Rutile"
  spec.required_ruby_version = ">= 3.4"
  spec.metadata["source_code_uri"] = "https://github.com/c0ze/Rutile"
  spec.metadata["changelog_uri"] = "https://github.com/c0ze/Rutile/blob/main/CHANGELOG.md"
  spec.metadata["documentation_uri"] = "https://github.com/c0ze/Rutile/blob/main/docs/wiki/Home.md"

  spec.files = Dir["lib/**/*.rb", "exe/*", "config/*.yml", "README.md"]
  spec.metadata["default_lint_roller_plugin"] = "RuboCop::Rutile::Plugin"
  spec.bindir = "exe"
  spec.executables = ["rutile"]
  spec.require_paths = ["lib"]

  # rbs-inline signatures are read with the RBS parser.
  spec.add_dependency "rbs", ">= 3.8"
end
