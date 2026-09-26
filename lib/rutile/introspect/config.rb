module Rutile
  module Introspect
    # Application settings that change what a request observes.
    module Config
      module_function

      def extract(app)
        {
          "api_only" => app.config.api_only,
          "time_zone" => app.config.time_zone,
          "default_locale" => I18n.default_locale.to_s,
          "active_record_default_timezone" => ActiveRecord.default_timezone.to_s,
          "error_message_files" => error_message_files(app)
        }
      end

      # The app's locale files that reword validation messages, which the
      # runtime writes as Rails' English defaults.
      def error_message_files(app)
        Dir.glob("config/locales/**/*.{yml,yaml}", base: app.root.to_s).sort.select do |path|
          locales = YAML.load_file(File.join(app.root, path), aliases: true)
          locales.is_a?(Hash) && locales.values.any? do |tree|
            tree.is_a?(Hash) && (tree["errors"] || tree.dig("activerecord", "errors") || tree.dig("activemodel", "errors"))
          end
        end
      end
    end
  end
end
