require "json"
require "prism"
require "set"

module Rutile
  # `rutile build`: the manifest plus the app's Ruby, written out as a Cargo
  # crate that runs on RustOnRails.
  module Build
    class Error < StandardError; end

    # A construct outside the subset Rutile compiles.
    class Unsupported < Error
      def self.at(path, node, what) = new("#{path}:#{node.location.start_line}: #{what} isn't supported yet")
    end

    # Introspects the app (unless handed a manifest) and writes the crate.
    def self.run(app_dir:, out:, runtime:, name: File.basename(app_dir), manifest: nil, env: "development", vars: {})
      manifest ||= Introspect.run(app_dir:, env:, out: File.join(app_dir, "tmp/rutile/manifest.json"), vars:)
      Crate.new(App.new(app_dir, JSON.parse(File.read(manifest))), out, name:, runtime:).write
    end
  end
end

require_relative "build/diagnostics"
require_relative "build/names"
require_relative "build/types"
require_relative "build/source"
require_relative "build/regexp"
require_relative "build/declarations"
require_relative "build/app"
require_relative "build/borrowing"
require_relative "build/model_calls"
require_relative "build/record_methods"
require_relative "build/records"
require_relative "build/web_calls"
require_relative "build/control_flow"
require_relative "build/expressions"
require_relative "build/constants"
require_relative "build/queries"
require_relative "build/scope_parameters"
require_relative "build/translator"
require_relative "build/scopes_file"
require_relative "build/validators"
require_relative "build/model_macros"
require_relative "build/model_methods"
require_relative "build/behavior"
require_relative "build/model_file"
require_relative "build/rescues"
require_relative "build/controller_file"
require_relative "build/application_controller_file"
require_relative "build/routes_file"
require_relative "build/crate"
