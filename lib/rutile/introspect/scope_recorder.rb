require_relative "source"

module Rutile
  module Introspect
    # Rails keeps no list of a model's scopes, so record `scope` calls while
    # the models load. install! has to run before eager loading.
    module ScopeRecorder
      @scopes = Hash.new { |hash, key| hash[key] = [] }

      def self.install!
        ActiveRecord::Base.singleton_class.prepend(Hook)
      end

      def self.record(model, name, body)
        location = body.source_location if body.respond_to?(:source_location)
        source = Source.location(*location)
        @scopes[model.name] << { "name" => name.to_s, "origin" => source ? "app" : "framework", "source" => source }
      end

      # A model sees every scope declared on it or on an ancestor below
      # ActiveRecord::Base (ApplicationRecord, an STI parent); the nearest
      # declaration of a name wins.
      def self.scopes_for(model)
        owners = model.ancestors.grep(Class).take_while { _1 != ActiveRecord::Base }.reverse
        owners.each_with_object({}) do |owner, found|
          @scopes.fetch(owner.name, []).each { found[_1["name"]] = _1 }
        end.values.sort_by { _1["name"] }
      end

      module Hook
        def scope(name, body, &block)
          ScopeRecorder.record(self, name, body)
          super
        end
      end
    end
  end
end
