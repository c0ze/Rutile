require_relative "source"

module Rutile
  module Introspect
    # Callback chains (model callbacks, controller filters) as data. Rails keeps
    # :if/:unless and before_action's only:/except: in instance variables with
    # no public reader, so this file is tied to Rails 8.1.
    module Callbacks
      module_function

      def entry(callback, owner)
        {
          "kind" => callback.kind.to_s,
          "filter" => filter(callback.filter, owner),
          "if" => conditions(callback.instance_variable_get(:@if), owner),
          "unless" => conditions(callback.instance_variable_get(:@unless), owner)
        }
      end

      def filter(value, owner)
        case value
        when Symbol
          source = Source.method_location(owner, value)
          { "method" => value.to_s, "origin" => method_origin(owner, value, source), "source" => source }
        when Proc
          source = Source.location(*value.source_location)
          { "proc" => source, "origin" => source ? "app" : "framework", **secure_token(value) }
        else
          { "object" => value.class.name, "origin" => Source.app_defined?(value.class) ? "app" : "framework" }
        end
      end

      # before_action's only:/except: become ActionFilter conditions; only:
      # lands in "if", except: in "unless".
      def conditions(list, owner)
        list.map do |condition|
          if condition.is_a?(AbstractController::Callbacks::ActionFilter)
            { "actions" => condition.instance_variable_get(:@actions).to_a.sort }
          else
            filter(condition, owner)
          end
        end
      end

      # has_secure_token's callback keeps its attribute and length only in
      # the block's closure.
      def secure_token(block)
        return {} unless block.source_location&.first&.end_with?("/active_record/secure_token.rb")

        binding = block.binding
        { "secure_token" => { "attribute" => binding.local_variable_get(:attribute).to_s,
                              "length" => binding.local_variable_get(:length) } }
      rescue NameError, ArgumentError
        {}
      end

      def method_origin(owner, name, source)
        return "missing" unless owner.method_defined?(name) || owner.private_method_defined?(name)

        source ? "app" : "framework"
      end
    end
  end
end
