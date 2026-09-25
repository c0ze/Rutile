require_relative "source"
require_relative "config"
require_relative "tables"
require_relative "models"
require_relative "routes"
require_relative "controllers"
require_relative "gems"

module Rutile
  module Introspect
    # Assembles the manifest. Every section comes out in a fixed order so two
    # runs over the same app produce byte-identical JSON.
    module Manifest
      VERSION = 3

      module_function

      def build(app)
        {
          "manifest_version" => VERSION,
          "rails_version" => Rails.version,
          "ruby_version" => RUBY_VERSION,
          "config" => Config.extract(app),
          "tables" => Tables.extract,
          "models" => Models.extract,
          "routes" => Routes.extract(app),
          "controllers" => Controllers.extract,
          "gems" => Gems.extract
        }
      end
    end
  end
end
