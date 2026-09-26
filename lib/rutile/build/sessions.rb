module Rutile
  module Build
    # `session` and `cookies` in a controller, and `reset_session`. The
    # session is Rails' cookie store, which RustOnRails reads and writes
    # in Rails' own format, so both can serve one user. A session value is
    # a Value: JSON gives it back as nil, a boolean, a number or a string.
    module Sessions
      private

      def session_call(node, name, args)
        unsupported!(node, "#{name} with arguments") unless args.empty?
        store = @app.manifest.dig("config", "session")
        if name != "cookies" && store&.dig("store") != "cookie"
          unsupported!(node, store ? "a session in #{store["store"]}" : "session without a session store")
        end
        # An API controller has `cookies` only through ActionController::Cookies.
        if name == "cookies" && !(@controller.respond_to?(:cookies?) && @controller.cookies?)
          unsupported!(node, "cookies in a controller without ActionController::Cookies")
        end
        case name
        when "session" then Code["req.session", T::SESSION]
        when "cookies" then Code["req.cookies", T::COOKIES]
        else Code["req.session.reset()?", T::UNIT, :write]
        end
      end

      # `session[:key]`, `session[:key] = value`, `session.delete(:key)`.
      # Reading loads the session, so it counts as a write: it's bound
      # before anything else borrows the request.
      def on_session(receiver, node, name, args)
        case [name, args.size]
        when ["[]", 1] then Code["#{receiver.rust}.get(#{session_key(args.first, node)})?", T::VALUE, :write, hint: "value"]
        when ["delete", 1] then Code["#{receiver.rust}.delete(#{session_key(args.first, node)})?", T::VALUE, :write, hint: "value"]
        when ["[]=", 2]
          key = session_key(args.first, node)
          value = settle([value(args.last)], :write).first
          stored = to_value(value) or unsupported!(node, "keeping #{describe(value.type)} in the session")
          @lines << "#{receiver.rust}.set(#{key}, #{stored.rust})?;"
          Code["()", T::UNIT]
        end
      end

      # `cookies[:name]` (a Value: the String, or nil) and
      # `cookies[:name] = "value"`.
      def on_cookies(receiver, node, name, args)
        case [name, args.size]
        when ["[]", 1] then Code["Value::from(#{receiver.rust}.get(#{session_key(args.first, node)}))", T::VALUE, :write, hint: "cookie"]
                            .tap { @uses.rt("Value") }
        when ["[]=", 2]
          key = session_key(args.first, node)
          value = settle([value(args.last)], :write).first
          text = case value.type
                 when T::STR then owned(value, T::STR)
                 when T::VALUE then "#{value.rust}.to_s()"
                 else unsupported!(node, "a cookie of #{describe(value.type)}")
                 end
          @lines << "#{receiver.rust}.set(#{key}, #{text});"
          Code["()", T::UNIT]
        end
      end

      def session_key(node, at)
        unless node.is_a?(Prism::SymbolNode) || node.is_a?(Prism::StringNode)
          unsupported!(at, "a session or cookie key that isn't a literal")
        end
        Names.str(node.unescaped)
      end
    end
  end
end
