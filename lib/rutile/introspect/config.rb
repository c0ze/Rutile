module Rutile
  module Introspect
    # Application settings that change what a request observes.
    module Config
      module_function

      def extract(app)
        {
          "api_only" => app.config.api_only,
          "time_zone" => app.config.time_zone,
          "default_locale" => I18n.default_locale.to_s,
          "active_record_default_timezone" => ActiveRecord.default_timezone.to_s,
          "session" => session(app)
        }
      end

      # The session store the middleware stack runs, if any: the cookie
      # store with its cookie's name, or another store by class.
      def session(app)
        cookies = app.middleware.any? { _1.klass == ActionDispatch::Cookies }
        middleware = app.middleware.find { _1.klass.to_s.start_with?("ActionDispatch::Session::") }
        return nil unless middleware && cookies

        store = middleware.klass
        return { "store" => store.to_s } unless store == ActionDispatch::Session::CookieStore

        options = middleware.args.grep(Hash).first || app.config.session_options || {}
        { "store" => "cookie", "key" => (options[:key] || "_#{app.class.module_parent_name.underscore}_session").to_s }
      end
    end
  end
end
