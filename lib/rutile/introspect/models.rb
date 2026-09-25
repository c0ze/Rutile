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
          "enum_methods" => enum_methods(model),
          "normalizations" => normalizations(model),
          "overrides" => overrides(model),
          "callbacks" => callbacks(model, validators),
          "scopes" => ScopeRecorder.scopes_for(model)
        }
      end

      # Rails keeps an association's `-> { ... }` outside its options; it goes
      # in as "scope" so build refuses it like any option it doesn't know.
      def association(reflection)
        options = Serialize.value(reflection.options)
        options["scope"] = true if reflection.scope
        {
          "macro" => reflection.macro.to_s,
          "name" => reflection.name.to_s,
          "class_name" => reflection.class_name,
          "foreign_key" => reflection.foreign_key.to_s,
          "options" => options
        }
      end

      # `normalizes :email, with: ...`: Rails wraps the attribute's type in a
      # NormalizedValueType holding the normalizer, once per `normalizes`, so
      # the innermost runs first. Other decorators (an enum, `encrypts`) may
      # wrap it too; they're passed through.
      def normalizations(model)
        return {} unless model.respond_to?(:normalized_attributes)

        model.normalized_attributes.map(&:to_s).sort.to_h do |name|
          [name, normalizers(model.type_for_attribute(name))]
        end
      end

      def normalizers(type, found = [], depth = 0)
        return found if type.nil? || depth > 10

        if type.respond_to?(:normalizer)
          found.unshift({ "with" => Serialize.value(type.normalizer), "apply_to_nil" => type.normalize_nil? })
          return normalizers(type.cast_type, found, depth + 1)
        end
        inner = if type.respond_to?(:cast_type) then type.cast_type
                elsif type.respond_to?(:subtype) then type.subtype
                end
        normalizers(inner, found, depth + 1)
      end

      # The methods `enum` defined: `done?` and `done!`, or none with
      # `instance_methods: false`, or `status_done?` with `prefix: true`.
      def enum_methods(model)
        return [] unless model.respond_to?(:_enum_methods_module, true)

        model.send(:_enum_methods_module).instance_methods(false).map(&:to_s).sort
      end

      # Methods the app defines (in the model, ApplicationRecord or a
      # concern) that replace one of Active Record's, which Rails' own code
      # then calls: `destroy`, `readonly?`, and class methods such as
      # `self.generate_unique_secure_token`.
      def overrides(model)
        base = ActiveRecord::Base
        instance = replaced(model.ancestors, base, "") { base.method_defined?(_1) || base.private_method_defined?(_1) }
        singleton = replaced(model.singleton_class.ancestors, base.singleton_class, "self.") { base.respond_to?(_1, true) }
        (instance + singleton).uniq { _1["name"] }.sort_by { _1["name"] }
      end

      def replaced(ancestors, base, prefix)
        ancestors.take_while { _1 != base }.flat_map do |owner|
          (owner.instance_methods(false) + owner.private_instance_methods(false)).filter_map do |name|
            next unless yield(name)

            source = Source.location(*owner.instance_method(name).source_location)
            source && { "name" => "#{prefix}#{name}", "source" => source }
          end
        end
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
