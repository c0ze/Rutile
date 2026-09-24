require_relative "serialize"

module Rutile
  module Introspect
    # The app's routes in match order.
    module Routes
      module_function

      def extract(app)
        app.routes.routes.map do |route|
          {
            "verb" => route.verb,
            "path" => route.path.spec.to_s,
            "controller" => route.defaults[:controller],
            "action" => route.defaults[:action],
            "name" => route.name,
            "requirements" => Serialize.value(route.requirements.except(:controller, :action))
          }
        end
      end
    end
  end
end
