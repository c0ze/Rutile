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
      # runtime writes as Rails' English defaults: every file I18n loads from
      # inside the app, wherever config.i18n.load_path puts it, but not from
      # gems installed there (bundle config path vendor/bundle), whose
      # locales are Rails' own. A Ruby locale file can't be read without
      # running it, so it counts.
      def error_message_files(app)
        root = "#{app.root}/"
        paths = (I18n.load_path.flatten.map(&:to_s) + Dir.glob("#{root}config/locales/**/*.{yml,yaml,rb}")).uniq
        mine = paths.select { |path| path.start_with?(root) && Gem.path.none? { |gems| path.start_with?("#{gems}/") } }
        mine.select { File.file?(_1) && rewords_errors?(_1) }.map { _1.delete_prefix(root) }.sort
      end

      def rewords_errors?(path)
        return true if path.end_with?(".rb")

        locales = YAML.load_file(path, aliases: true)
        locales.is_a?(Hash) && locales.values.any? do |tree|
          tree.is_a?(Hash) && (tree["errors"] || tree.dig("activerecord", "errors") || tree.dig("activemodel", "errors"))
        end
      end
    end
  end
end
