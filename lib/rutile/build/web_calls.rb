module Rutile
  module Build
    # Controller calls: params, render and head, as_json, and the request
    # values route constraints read.
    module WebCalls
      STATUSES = {
        "ok" => 200, "created" => 201, "accepted" => 202, "no_content" => 204, "moved_permanently" => 301, "found" => 302,
        "see_other" => 303, "not_modified" => 304, "bad_request" => 400, "unauthorized" => 401, "forbidden" => 403,
        "not_found" => 404, "conflict" => 409, "gone" => 410, "unprocessable_content" => 422, "unprocessable_entity" => 422,
        "too_many_requests" => 429, "internal_server_error" => 500, "service_unavailable" => 503
      }.freeze
      # The ones `rustonrails::status` names.
      NAMED = %w[ok created no_content bad_request not_found unprocessable_content internal_server_error].freeze

      private

      def controller_call(node, name, args)
        case name
        when "params" then args.empty? ? Code["req.params", T::PARAMS] : nil
        when "request" then args.empty? ? Code["req", T::REQUEST] : nil
        when "render" then render(node, args)
        when "head" then head(node, args)
        else
          return ivar_named(name, node) if args.empty? && @controller.reader?(name)

          type = @controller.helper(name, node) or return nil
          unsupported!(node, "calling #{name} with arguments") unless args.empty?
          Code["self.#{Names.method(name)}(req)?", type, :write, hint: name.end_with?("_params") ? "attributes" : name]
        end
      end

      def render(node, args)
        options = pairs(args, node).to_h
        extra = options.keys - %w[json status]
        unsupported!(node, "render with #{extra.join(", ")}") unless extra.empty?
        value = options["json"] or unsupported!(node, "render without json:")
        status = status_code(options["status"], node)
        json = json_of(expr(value), value)
        @uses.rt("Response")
        Code["Response::json(#{status}, #{json.rust})", T::RESPONSE, json.ctx]
      end

      def head(node, args)
        @uses.rt("Response")
        Code["Response::head(#{status_code(only(args, node), node)})", T::RESPONSE]
      end

      def status_code(node, at)
        name = node.nil? ? "ok" : node.is_a?(Prism::IntegerNode) ? (return node.value.to_s) : symbol!(node, at)
        code = STATUSES[name] or unsupported!(at, "status :#{name}")
        return code.to_s unless NAMED.include?(name)

        @uses.rt("status")
        "status::#{name.upcase}"
      end

      # What `render json:` makes of a value.
      def json_of(code, node)
        case code.type.kind
        when :json then code
        when :record then render_record(code, code.type.model, nil, node)
        when :relation then render_relation(code, code.type.model, nil, node)
        when :errors
          @uses.rt("errors_json")
          Code["errors_json(#{code.rust})", T::JSON, :read]
        when :nilable
          unsupported!(node, "render json: #{describe(code.type)}") unless code.type.inner.kind == :record
          receiver = settle([code], :write).first
          Code["#{as_json(code.type.inner.model, nil, node)}.render_option(#{ctx_mut}, #{receiver.rust})?", T::JSON, :write]
        else unsupported!(node, "render json: #{describe(code.type)}")
        end
      end

      def render_record(receiver, model, options, node)
        need_ctx!(node)
        receiver = settle([receiver], :write).first
        Code["#{as_json(model, options, node)}.render(#{ctx_mut}, #{receiver.rust})?", T::JSON, :write]
      end

      # Loads once into a local, then renders the records.
      def render_relation(receiver, model, options, node)
        need_ctx!(node)
        hint = receiver.extra[:local] ? "records" : receiver.hint
        records = bind(Code["#{receiver.rust}.load(#{ctx_mut})?", T.records(model), :write, hint:])
        Code["#{as_json(model, options, node)}.render_all(#{ctx_mut}, &#{records.rust})?", T::JSON, :write]
      end

      def as_json(model, options, node)
        @uses.rt("AsJson")
        use_model(model)
        builder = "AsJson::<#{model}>::new()"
        return builder if options.nil?

        pairs([options], node).each do |key, value|
          case key
          when "only", "except" then builder += ".#{key}(#{Names.str_slice(symbols(value, node))})"
          when "include" then builder += includes(model, value, node)
          else unsupported!(node, "as_json option #{key}")
          end
        end
        builder
      end

      def includes(model, value, node)
        hash = value.is_a?(Prism::HashNode) || value.is_a?(Prism::KeywordHashNode)
        entries = hash ? pairs([value], node) : symbols(value, node).map { [_1, nil] }
        entries.map do |name, options|
          assoc = @app.association(model, name) or unsupported!(node, "including #{name}, which #{model} doesn't have")
          (through = assoc["options"]["through"]) and unsupported!(node, "including #{name} through #{through}")
          method = assoc["macro"] == "has_many" ? "include_many" : "include"
          ".#{method}(&#{model}::#{Names.constant(name)}, #{as_json(assoc["class_name"], options, node)})"
        end.join
      end

      def symbols(node, at)
        case node
        when Prism::ArrayNode then node.elements.map { symbol!(_1, at) }
        when Prism::SymbolNode then [node.unescaped]
        else unsupported!(at, "a list that isn't symbols")
        end
      end

      # `{ error: "not found" }` as `json!`, values in Ruby's order.
      def json_literal(node)
        pairs = node.elements.each do |pair|
          key = pair.is_a?(Prism::AssocNode) && (pair.key.is_a?(Prism::SymbolNode) || pair.key.is_a?(Prism::StringNode))
          unsupported!(node, "a hash key that isn't a symbol or string") unless key
        end
        codes = in_order(pairs) do |pair|
          value = expr(pair.value)
          next Code["null", T::JSON] if value.type == T::NIL

          plain = [T::STR, T::INT, T::BOOL, T::FLOAT, T::JSON]
          value = json_of(value, pair.value) unless plain.include?(value.type) || (value.type.nilable? && plain.include?(value.type.inner))
          name = pair.key.unescaped
          value.hint || !name.match?(/\A[a-z_][a-z0-9_]*\z/) ? value : value.with(hint: name)
        end
        codes = settle(codes, :none)
        fields = pairs.zip(codes).map { |pair, code| "#{Names.str(pair.key.unescaped)}: #{owned(code)}" }
        @uses.rt("json")
        Code["json!({ #{fields.join(", ")} })", T::JSON, codes.any?(&:writes?) ? :write : (codes.any?(&:reads?) ? :read : :none)]
      end

      def on_params(receiver, node, name, args)
        case name
        when "[]"
          key = symbol!(only(args, node), node)
          Code["#{receiver.rust}.value(#{Names.str(key)})", T::VALUE, hint: key]
        when "require" then Code["#{receiver.rust}.require(#{Names.str(symbol!(only(args, node), node))})?", T::PARAMS, hint: "params"]
        when "permit" then Code["#{receiver.rust}.permit(#{Names.str_slice(args.map { symbol!(_1, node) })})", T::ATTRIBUTES, hint: "attributes"]
        when "expect"
          key, fields = only(pairs(args, node), node)
          Code["#{receiver.rust}.expect(#{Names.str(key)}, #{Names.str_slice(symbols(fields, node))})?", T::ATTRIBUTES,
               hint: "attributes"]
        end
      end

      # A param value. `blank?` is Value's own; `present?` comes from Blank.
      def on_value(receiver, _node, name, args)
        return nil unless args.empty?

        case name
        when "to_s" then Code["#{receiver.rust}.to_ruby_string()", T::STR, receiver.ctx, hint: receiver.hint]
        when "nil?" then Code["#{receiver.rust}.is_nil()", T::BOOL, receiver.ctx]
        when "blank?" then Code["#{receiver.rust}.is_blank()", T::BOOL, receiver.ctx]
        when "present?"
          @uses.rt("Blank")
          Code["#{receiver.rust}.is_present()", T::BOOL, receiver.ctx]
        end
      end

      def on_request(receiver, _node, name, args)
        return nil unless args.empty?

        case name
        when "query_parameters" then Code["#{receiver.rust}.query", T::QUERY]
        when "headers" then Code[receiver.rust, T::HEADERS]
        end
      end

      # `request.headers["X-Api-Token"]`. `header` borrows the whole request,
      # so it's a Ctx read: bound before any `&mut req.ctx` call.
      def on_headers(receiver, node, name, args)
        key = only(args, node)
        return nil unless name == "[]" && key.is_a?(Prism::StringNode)

        Code["#{receiver.rust}.header(#{Names.str(key.unescaped)})", T.nilable(T::STR), :read, hint: "header"]
      end

      def on_query(receiver, node, name, args)
        return nil unless name == "[]"

        key = only(args, node)
        unsupported!(node, "a query key that isn't a literal") unless key.is_a?(Prism::StringNode) || key.is_a?(Prism::SymbolNode)
        Code["#{receiver.rust}.get(#{Names.str(key.unescaped)})", T::JSON_OPT]
      end

      # A rescue handler's RecordInvalid. It carries the invalid record's
      # errors, which is all of the record a handler can read.
      def on_record_invalid(receiver, _node, name, args)
        Code[receiver.rust, T::INVALID_RECORD] if name == "record" && args.empty?
      end

      def on_invalid_record(receiver, _node, name, args)
        Code["&#{receiver.rust}.errors", T.errors(nil)] if name == "errors" && args.empty?
      end

      def on_json_opt(receiver, _node, name, args)
        return nil unless args.empty? && %w[present? blank?].include?(name)

        @uses.rt("Blank")
        Code["#{receiver.rust}.#{Names.method(name)}()", T::BOOL]
      end
    end
  end
end
