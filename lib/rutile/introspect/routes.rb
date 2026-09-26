require_relative "serialize"

module Rutile
  module Introspect
    # The app's routes in match order.
    module Routes
      module_function

      # Rails' own routes (`/rails/info`, the welcome page) are marked
      # internal, added in development only, and never the app's.
      def extract(app)
        app.routes.routes.reject(&:internal).map do |route|
          {
            "verb" => route.verb,
            "path" => route.path.spec.to_s,
            "controller" => route.defaults[:controller],
            "action" => route.defaults[:action],
            "name" => route.name,
            "requirements" => Serialize.value(route.requirements.except(:controller, :action)),
            "request_constraints" => Serialize.value(route.constraints),
            "callable_constraints" => callable_constraints(route)
          }
        end
      end

      # Lambdas and objects passed to `constraints` wrap the route's endpoint
      # (Rails 8.1 internals). When one returns false, Rails tries the next
      # route, so the runtime needs them.
      def callable_constraints(route)
        return [] unless route.app.is_a?(ActionDispatch::Routing::Mapper::Constraints)

        route.app.constraints.map { Serialize.value(_1) }
      end
    end
  end
end
