require_relative "source"
require_relative "config"
require_relative "tables"
require_relative "models"

module Rutile
  module Introspect
    # Assembles the manifest. Every section comes out in a fixed order so two
    # runs over the same app produce byte-identical JSON.
    module Manifest
      VERSION = 1

      module_function

      def build(app)
        {
          "manifest_version" => VERSION,
          "rails_version" => Rails.version,
          "ruby_version" => RUBY_VERSION,
          "config" => Config.extract(app),
          "tables" => Tables.extract,
          "models" => Models.extract
        }
      end
    end
  end
end
