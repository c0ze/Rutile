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

      def self.scopes_for(model)
        @scopes[model.name].sort_by { _1["name"] }
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
