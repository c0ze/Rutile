require "lint_roller"
require "pathname"
require "prism"
require_relative "version"
require_relative "check/rules"
require_relative "rubocop/subset"

module RuboCop
  module Rutile
    # The subset rules as a RuboCop plugin, so editors flag what `rutile
    # check` would reject as it's typed. In .rubocop.yml:
    #
    #   plugins:
    #     - rutile:
    #         require_path: rutile/rubocop
    class Plugin < LintRoller::Plugin
      CONFIG = Pathname(__dir__).join("../../config/rubocop.yml").expand_path

      def about
        LintRoller::About.new(name: "rutile", version: ::Rutile::VERSION, homepage: "https://github.com/c0ze/Rutile",
                              description: "Flags Ruby that Rutile can't compile to Rust.")
      end

      def supported?(context) = context.engine == :rubocop

      def rules(_context) = LintRoller::Rules.new(type: :path, config_format: :rubocop, value: CONFIG)
    end
  end
end
