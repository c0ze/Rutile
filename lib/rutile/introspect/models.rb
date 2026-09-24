require_relative "source"
require_relative "serialize"

module Rutile
  module Introspect
    # Every non-abstract Active Record model defined under app/.
    module Models
      module_function

      def app_models
        ActiveRecord::Base.descendants
          .reject(&:abstract_class?)
          .select { Source.app_defined?(_1) }
          .sort_by(&:name)
      end

      def extract
        app_models.map { describe(_1) }
      end

      def describe(model)
        {
          "name" => model.name,
          "table_name" => model.table_name,
          "source" => Source.const_location(model.name),
          # Every attribute Active Record knows, including `attribute` declarations with no column.
          "attributes" => model.attribute_types.sort.to_h { |name, type| [name, type.type.to_s] },
          "associations" => model.reflect_on_all_associations.map { association(_1) },
          "validators" => model.validators.map { validator(_1) },
          "enums" => model.defined_enums.sort.to_h { |name, mapping| [name, mapping.to_h] }
        }
      end

      def association(reflection)
        {
          "macro" => reflection.macro.to_s,
          "name" => reflection.name.to_s,
          "class_name" => reflection.class_name,
          "foreign_key" => reflection.foreign_key.to_s,
          "options" => Serialize.value(reflection.options)
        }
      end

      def validator(validator)
        {
          "kind" => validator.kind.to_s,
          "class" => validator.class.name,
          "attributes" => validator.respond_to?(:attributes) ? validator.attributes.map(&:to_s) : [],
          "options" => Serialize.value(validator.options)
        }
      end
    end
  end
end
