module Rutile
  module Build
    # The manifest, looked up the way the emitters ask, plus the app's source.
    class App
      COLUMN_TYPES = { "integer" => T::INT, "bigint" => T::INT, "string" => T::STR, "text" => T::STR,
                       "datetime" => T::TIME, "date" => T::DATE, "boolean" => T::BOOL, "float" => T::FLOAT }.freeze

      attr_reader :root, :manifest, :source

      def initialize(root, manifest, diagnostics: nil)
        @root = root
        @manifest = manifest
        @diagnostics = diagnostics
        @source = Source.new(root)
        @fallbacks = Set.new
      end

      # Where the build fell back to Value: `path:line: what falls back to Value`.
      def fallbacks = @fallbacks.sort_by { |message| [message[/\A[^:]+/], message[/:(\d+):/, 1].to_i, message] }

      def fallback(path, node, message) = @fallbacks << "#{path}:#{node.location.start_line}: #{message}"

      attr_reader :diagnostics

      # One unit of the build. With a collector, a failure is recorded and
      # `fallback` returned; without one it propagates as always.
      def attempt(fallback = nil, &block) = @diagnostics ? @diagnostics.attempt(fallback, &block) : yield

      def models = manifest.fetch("models")
      def model(name) = models.find { _1["name"] == name } || raise(Error, "no model #{name}")
      def model?(name) = models.any? { _1["name"] == name }
      def model_path(name) = model(name).dig("source", "path")

      # The model's table. A view isn't among the manifest's tables.
      def table(name)
        table_name = model(name)["table_name"]
        manifest.fetch("tables").find { _1["name"] == table_name } ||
          raise(Unsupported, "#{model_path(name)}: #{name} on #{table_name}, which isn't a table (a view, say), isn't supported yet")
      end

      def columns(name) = table(name).fetch("columns")

      def column(name, column) = columns(name).find { _1["name"] == column.to_s }

      # What generated code holds for the attribute; enums hold labels.
      # Nil when the model has no such column.
      def column_type(name, column)
        return T::STR if enum(name, column)

        found = column(name, column) or return nil
        COLUMN_TYPES.fetch(found["type"]) do
          raise Unsupported, "#{model_path(name)}: #{found["type"]} column #{found["name"]} isn't supported yet"
        end
      end

      def association(name, assoc) = model(name)["associations"].find { _1["name"] == assoc.to_s }
      def enum(name, attribute) = model(name)["enums"][attribute.to_s]
      # The attribute's normalizers, innermost (first to run) first; nil if none.
      def normalization(name, attribute) = model(name)["normalizations"][attribute.to_s]

      # The app's methods that replace one of Active Record's.
      def overrides(name) = model(name)["overrides"]

      # `draft?` → ["status", "draft"] when it's an enum predicate `enum`
      # defined (not with `prefix:`, `suffix:` or `instance_methods: false`).
      def enum_predicate(name, method) = enum_method(name, method, "?")

      # `done!` → ["status", "done"] when it's an enum's bang method.
      def enum_bang(name, method) = enum_method(name, method, "!")

      def enum_method(name, method, suffix)
        return nil unless method.to_s.end_with?(suffix) && model(name)["enum_methods"].include?(method.to_s)

        label = method.to_s.delete_suffix(suffix)
        model(name)["enums"].each { |attribute, values| return [attribute, label] if values.key?(label) }
        nil
      end

      # The models' own instance methods, translated once for every caller.
      def model_methods = @model_methods ||= ModelMethods.new(self)

      # `will_save_change_to_status?` → "status" when it's a column.
      def change_to_save(name, method)
        column = method.to_s[/\Awill_save_change_to_(\w+)\?\z/, 1]
        column if column && column(name, column)
      end

      # `saved_change_to_status?`, which describes the last save.
      def saved_change?(method) = method.to_s.match?(/\Asaved_change_to_\w+\?\z/)

      def scope(name, scope) = model(name)["scopes"].find { _1["name"] == scope.to_s }

      # The runtime reads and writes times in UTC and writes Rails' English
      # validation messages, which are Rails' defaults. Another zone changes
      # how `render json:` writes a time and where a date's day starts in a
      # query; another locale or reworded messages change every error
      # response. The build refuses them rather than differ.
      def defaults!
        config = manifest.fetch("config")
        zone, stored, locale = config.values_at("time_zone", "active_record_default_timezone", "default_locale")
        raise Unsupported, "config/application.rb: config.time_zone #{zone} isn't supported yet" unless zone == "UTC"
        raise Unsupported, "config/application.rb: active_record.default_timezone #{stored} isn't supported yet" unless stored == "utc"
        raise Unsupported, "config/application.rb: the default locale #{locale} isn't supported yet" unless locale == "en"

        reworded = config.fetch("error_message_files").first
        raise Unsupported, "#{reworded}: validation messages set in a locale file aren't supported yet" if reworded
      end

      def controllers = manifest.fetch("controllers")

      # The Active Job classes, when Sidekiq runs them: what Rutile compiles.
      def jobs = manifest.dig("jobs", "adapter") == "sidekiq" ? manifest.dig("jobs", "classes") : []
      def job(name) = jobs.find { _1["name"] == name }
      def controller(name) = controllers.find { _1["name"] == name } || raise(Error, "no controller #{name}")
      def routes = manifest.fetch("routes")

      # The app's templates by name (`storefront/index`), HTML ones only.
      def views = manifest.fetch("views", [])
      def view(name) = views.find { _1["name"] == name && _1["format"] == "html" && !_1["partial"] }
    end
  end
end
