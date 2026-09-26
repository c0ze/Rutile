require_relative "target"

# Loaded into the app's test process by `rutile verify` (through RUBYOPT),
# so the app needs no change: once `rails/test_help` has loaded, integration
# tests go to the server at RUTILE_TARGET. `require` is wrapped the way
# Zeitwerk wraps it, on Kernel and on Kernel itself: Ruby's bundled-gems
# check calls down through `Kernel.require`.
module Rutile
  module Verify
    module Hook
      # How many requests went to the target, written at exit for
      # `rutile verify` to check: tests that never reached it prove nothing.
      def self.required(path)
        return unless path == "rails/test_help" || path.to_s.end_with?("/rails/test_help.rb")

        target = Target.install(ENV.fetch("RUTILE_TARGET"))
        return unless (log = ENV["RUTILE_VERIFY_LOG"])

        at_exit { File.write(log, target.forwarded.to_s) }
      end
    end
  end
end

if ENV["RUTILE_TARGET"]
  [Kernel, Kernel.singleton_class].each do |kernel|
    kernel.class_eval do
      alias_method :rutile_verify_original_require, :require

      define_method(:require) do |path|
        loaded = rutile_verify_original_require(path)
        Rutile::Verify::Hook.required(path) if loaded
        loaded
      end
    end
  end
  Kernel.send(:private, :require, :rutile_verify_original_require)
end
