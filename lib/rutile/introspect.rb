require "fileutils"
require "open3"
require_relative "unbundled"
require_relative "introspect/manifest_version"

module Rutile
  # Host side of `rutile introspect`: runs introspect/runner.rb inside the
  # target app with `bin/rails runner`. The runner writes the manifest.
  module Introspect
    class Error < StandardError; end

    RUNNER = File.expand_path("introspect/runner.rb", __dir__)

    module_function

    # vars: extra environment variables for the app process.
    def run(app_dir:, env:, out:, vars: {})
      rails = File.join(app_dir, "bin/rails")
      raise Error, "no bin/rails in #{app_dir}" unless File.exist?(rails)

      FileUtils.mkdir_p(File.dirname(out))
      FileUtils.rm_f(out)
      child_env = vars.merge("RAILS_ENV" => env, "RUTILE_MANIFEST_OUT" => out)
      _stdout, stderr, status = Rutile.unbundled do
        Open3.capture3(child_env, rails, "runner", RUNNER, chdir: app_dir)
      end
      unless status.success? && File.exist?(out)
        raise Error, "bin/rails runner failed in #{app_dir}:\n#{excerpt(stderr)}"
      end

      out
    end

    # Ruby prints the exception first and the backtrace after it, so a long
    # boot failure keeps both ends.
    def excerpt(output, keep: 20)
      lines = output.lines
      return lines.join if lines.size <= keep * 2

      (lines.first(keep) + ["...\n"] + lines.last(keep)).join
    end
  end
end
