require "prism"
require_relative "rutile/version"
require_relative "rutile/introspect"
require_relative "rutile/build"
require_relative "rutile/check"
require_relative "rutile/verify"
require_relative "rutile/package"
# `plugins: rutile` in .rubocop.yml: RuboCop looks the plugin up by the
# name in the gemspec, whenever this file was loaded.
module RuboCop
  module Rutile
    autoload :Plugin, File.expand_path("rutile/rubocop", __dir__)
  end
end
require_relative "rutile/cli"

# Rutile compiles Rails apps written in a strict subset of Ruby to Rust.
# See docs/design.md.
module Rutile
end
