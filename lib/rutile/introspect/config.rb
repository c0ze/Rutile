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
          "session" => session(app),
          "cookies_same_site" => symbol_or_class(app.config.action_dispatch.cookies_same_site_protection),
          "force_ssl" => app.config.force_ssl == true,
          "assume_ssl" => app.config.assume_ssl == true,
          "ssl_options" => JSON.parse(JSON.generate(app.config.ssl_options)),
          "default_headers" => (app.config.action_dispatch.default_headers || {}).to_a
        }
      end

      # A Symbol as its name; a Proc (decided per request) by its class.
      def symbol_or_class(value) = value.is_a?(Symbol) || value.nil? ? value&.to_s : { "dynamic" => value.class.name }

      # The session store the middleware stack runs, if any: the cookie
      # store with its cookie's name, or another store by class.
      def session(app)
        cookies = app.middleware.any? { _1.klass == ActionDispatch::Cookies }
        middleware = app.middleware.find { _1.klass.to_s.start_with?("ActionDispatch::Session::") }
        return nil unless middleware && cookies

        store = middleware.klass
        return { "store" => store.to_s } unless store == ActionDispatch::Session::CookieStore

        # Rails' default stack hands the store its session_options; a store
        # added by hand without options has Rack's default name.
        options = middleware.args.grep(Hash).first || {}
        {
          "store" => "cookie",
          "key" => (options[:key] || "_session_id").to_s,
          "path" => (options[:path] || "/").to_s,
          "secure" => options[:secure] == true,
          "httponly" => options.fetch(:httponly, true) != false,
          "same_site" => options.key?(:same_site) ? symbol_or_class(options[:same_site]) : "default",
          "domain" => options[:domain]&.to_s,
          "expire_after" => options[:expire_after]&.to_i
        }
      end
    end
  end
end
