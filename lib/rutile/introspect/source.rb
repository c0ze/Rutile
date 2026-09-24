module Rutile
  module Introspect
    # File locations in the manifest, relative to the app root. Anything
    # outside the app (Rails, gems, Ruby) gets no location, so a manifest
    # doesn't depend on where gems happen to be installed. Gems vendored
    # inside the app (bundle config path vendor/bundle) count as outside.
    module Source
      module_function

      def location(path = nil, line = nil)
        root = "#{Rails.root}/"
        return nil unless path&.start_with?(root)
        return nil if Gem.path.any? { path.start_with?("#{_1}/") }

        { "path" => path.delete_prefix(root), "line" => line }
      end

      def const_location(name)
        location(*Object.const_source_location(name))
      end

      def method_location(owner, name)
        location(*owner.instance_method(name).source_location)
      rescue NameError
        nil
      end

      def app_defined?(klass)
        return false unless klass.name

        const_location(klass.name)&.fetch("path")&.start_with?("app/") || false
      end
    end
  end
end
