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
          "error_message_files" => error_message_files(app),
          "session" => session(app),
          "cookies_same_site" => symbol_or_class(app.config.action_dispatch.cookies_same_site_protection),
          "force_ssl" => app.config.force_ssl == true,
          "assume_ssl" => app.config.assume_ssl == true,
          "ssl_options" => JSON.parse(JSON.generate(app.config.ssl_options)),
          "default_headers" => (app.config.action_dispatch.default_headers || {}).to_a
        }
      end

      # How Rails writes and reads the encrypted cookie the store uses: the
      # serializer, the cipher, the key's salt, the purpose metadata, and
      # any rotations to older settings.
      def cookie_format(app)
        env = app.env_config
        rotations = env["action_dispatch.cookies_rotations"]
        {
          "serializer" => env["action_dispatch.cookies_serializer"]&.to_s,
          "authenticated_encryption" => env["action_dispatch.use_authenticated_cookie_encryption"] == true,
          "cipher" => env["action_dispatch.encrypted_cookie_cipher"]&.to_s,
          "salt" => env["action_dispatch.authenticated_encrypted_cookie_salt"]&.to_s,
          "metadata" => env["action_dispatch.use_cookies_with_metadata"] == true,
          "rotations" => rotations.respond_to?(:encrypted) ? rotations.encrypted.size : 0,
          # The digest the cookie's key is derived with from secret_key_base.
          "key_digest" => ActiveSupport::KeyGenerator.hash_digest_class.name
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
          "expire_after" => options[:expire_after]&.to_i,
          "cookie_format" => cookie_format(app)
        }
      end

      # The app's locale files that reword validation messages, which the
      # runtime writes as Rails' English defaults: every file I18n loads from
      # inside the app, wherever config.i18n.load_path puts it, but not from
      # gems installed there (bundle config path vendor/bundle), whose
      # locales are Rails' own. A Ruby locale file can't be read without
      # running it, so it counts.
      def error_message_files(app)
        root = "#{app.root}/"
        paths = (I18n.load_path.flatten.map(&:to_s) + Dir.glob("#{root}config/locales/**/*.{yml,yaml,rb}")).uniq
        mine = paths.select { |path| path.start_with?(root) && Gem.path.none? { |gems| path.start_with?("#{gems}/") } }
        mine.select { File.file?(_1) && rewords_errors?(_1) }.map { _1.delete_prefix(root) }.sort
      end

      def rewords_errors?(path)
        return true if path.end_with?(".rb")

        locales = YAML.load_file(path, aliases: true)
        locales.is_a?(Hash) && locales.values.any? do |tree|
          tree.is_a?(Hash) && (tree["errors"] || tree.dig("activerecord", "errors") || tree.dig("activemodel", "errors"))
        end
      end
    end
  end
end
