require_relative "lib/rutile/version"

Gem::Specification.new do |spec|
  spec.name = "rutile"
  spec.version = Rutile::VERSION
  spec.authors = ["Arda Karaduman"]
  spec.email = ["arda@gand.tr"]

  spec.summary = "Compiles Rails apps written in a strict subset of Ruby to Rust."
  spec.required_ruby_version = ">= 3.4"

  spec.files = Dir["lib/**/*.rb", "exe/*", "README.md"]
  spec.bindir = "exe"
  spec.executables = ["rutile"]
  spec.require_paths = ["lib"]
end
