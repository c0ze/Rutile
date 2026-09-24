module Rutile
  module Build
    # The manifest, looked up the way the emitters ask, plus the app's source.
    class App
      COLUMN_TYPES = { "integer" => T::INT, "bigint" => T::INT, "string" => T::STR, "text" => T::STR,
                       "datetime" => T::TIME, "boolean" => T::BOOL, "float" => T::FLOAT }.freeze

      attr_reader :root, :manifest, :source

      def initialize(root, manifest)
        @root = root
        @manifest = manifest
        @source = Source.new(root)
      end

      def models = manifest.fetch("models")
      def model(name) = models.find { _1["name"] == name } || raise(Error, "no model #{name}")
      def model?(name) = models.any? { _1["name"] == name }
      def model_path(name) = model(name).dig("source", "path")

      def table(name) = manifest.fetch("tables").find { _1["name"] == model(name)["table_name"] }

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

      # `draft?` → ["status", "draft"] when it's an enum predicate.
      def enum_predicate(name, method)
        return nil unless method.to_s.end_with?("?")

        label = method.to_s.delete_suffix("?")
        model(name)["enums"].each { |attribute, values| return [attribute, label] if values.key?(label) }
        nil
      end

      def scope(name, scope) = model(name)["scopes"].find { _1["name"] == scope.to_s }

      def controllers = manifest.fetch("controllers")
      def controller(name) = controllers.find { _1["name"] == name } || raise(Error, "no controller #{name}")
      def routes = manifest.fetch("routes")
    end
  end
end
