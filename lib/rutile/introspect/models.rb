require_relative "source"
require_relative "serialize"
require_relative "callbacks"
require_relative "scope_recorder"

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
        validators = validators_in_order(model)
        {
          "name" => model.name,
          "table_name" => model.table_name,
          "source" => Source.const_location(model.name),
          # Every attribute Active Record knows, including `attribute` declarations with no column.
          "attributes" => model.attribute_types.sort.to_h { |name, type| [name, type.type.to_s] },
          "associations" => model.reflect_on_all_associations.map { association(_1) },
          "validators" => validators.map { validator(_1) },
          "enums" => model.defined_enums.sort.to_h { |name, mapping| [name, mapping.to_h] },
          "callbacks" => callbacks(model, validators),
          "scopes" => ScopeRecorder.scopes_for(model)
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

      # Validators in the order they run: Rails registers each one as a
      # validate callback, interleaved with `validate :method` calls.
      def validators_in_order(model)
        model.__callbacks.fetch(:validate, []).map(&:filter).grep(ActiveModel::Validator)
      end

      # A validator's slot in the validate chain points into "validators"
      # instead of repeating it, so the chain keeps the real run order.
      def callbacks(model, validators)
        model.__callbacks.sort.each_with_object({}) do |(event, chain), out|
          entries = chain.map do |callback|
            index = validators.index(callback.filter) if callback.filter.is_a?(ActiveModel::Validator)
            index ? { "kind" => callback.kind.to_s, "validator" => index } : Callbacks.entry(callback, model)
          end
          out[event.to_s] = entries unless entries.empty?
        end
      end
    end
  end
end
