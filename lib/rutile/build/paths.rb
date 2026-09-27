module Rutile
  module Build
    # Route helpers (0.10): `shop_product_path(product)` for each named
    # route, generated into src/routes.rs, with each segment escaped as
    # Journey escapes one.
    module Paths
      FORMAT = "(.:format)"

      module_function

      # The required segments of `path`, or nil for a path with other
      # optional parts or a glob, which the helpers don't fill.
      def segments(path)
        bare = path.delete_suffix(FORMAT)
        return nil if bare.match?(/[()*]/)

        bare.scan(/:(\w+)/).flatten
      end

      # The helper for each named route whose segments it can fill.
      def functions(app)
        app.routes.filter_map do |route|
          keys = route["name"] && segments(route["path"]) or next
          path = route["path"].delete_suffix(FORMAT)
          template = path.gsub(/[{}]/) { _1 * 2 }.gsub(/:\w+/, "{}")
          values = keys.map { "path_segment(#{Names.ident(_1)}, #{Names.str(route["controller"])}, #{Names.str(route["action"])}, #{Names.str(_1)})?" }
          format = keys.empty? ? "#{Names.str(path)}.to_string()" : "format!(#{Names.str(template)}, #{values.join(", ")})"
          params = keys.map { "#{Names.ident(_1)}: impl ToParam" }.join(", ")
          "/// `#{route["name"]}_path`: #{route["path"]}\npub fn #{route["name"]}_path(#{params}) -> Result<String> {\nOk(#{format})\n}"
        end
      end
    end

    # Calling a route helper from a controller or a view.
    module PathCalls
      private

      def path_helper(node, name, args)
        return nil unless name.end_with?("_path")

        route = @app.routes.find { _1["name"] == name.delete_suffix("_path") } or return nil
        unsupported!(node, "#{name} with options") if args.last.is_a?(Prism::KeywordHashNode)
        path_call(route, in_order(args) { value(_1) }, node, name)
      end

      # `link_to name, record`: the path of the model's singular route.
      def path_for(model, codes, node)
        key = Names.snake(model)
        route = @app.routes.find { _1["name"] == key } or unsupported!(node, "a link to a #{model}, with no route named #{key}")
        path_call(route, codes, node, "#{key}_path").rust
      end

      def path_call(route, codes, node, name)
        keys = Paths.segments(route["path"]) or unsupported!(node, "#{name}, whose path #{route["path"]} has optional parts")
        unsupported!(node, "#{name} with #{codes.size} arguments for #{keys.size}") unless codes.size == keys.size

        values = codes.map { param_of(_1, node, name) }
        Code["crate::routes::#{name}(#{values.join(", ")})?", T::STR, touch(*codes)]
      end

      # What `to_param` gives: a record's id, a number, a String.
      def param_of(code, node, name)
        case code.type
        when T::INT, T::VALUE, T.nilable(T::INT) then owned(code)
        when T::STR then "&#{code.rust}"
        else
          return "#{ctx_recv}[#{code.rust}].id" if code.type.kind == :record

          unsupported!(node, "#{name} with #{describe(code.type)}")
        end
      end
    end
  end
end
