module Rutile
  module Build
    # `map` with a block over a relation, and what renders its result: the
    # records load once, the block's body runs in a `for` loop over them,
    # and each value it ends on is pushed onto a `Vec`. A `for` loop rather
    # than a closure, so the body can borrow the Ctx and use `?` as the
    # method around it does. Also `merge` on a hash `as_json` made.
    module Blocks
      # What a mapped list may hold.
      ELEMENTS = %i[json str int bool record].freeze

      private

      def map_block(node)
        block = node.block
        name = block_parameter(block, node)
        need_ctx!(node)
        receiver = expr(node.receiver)
        unsupported!(node, "map over #{describe(receiver.type)}") unless receiver.type.kind == :relation

        model = receiver.type.model
        records = bind(Code["#{receiver.rust}.load(#{ctx_mut})?", T.records(model), :write, hint: "records"])
        rust = [*Translator::KEYWORDS, "ctx", "req", "self", @self_var].include?(name) ? fresh("record") : name
        lines, value = in_block(name, Code[rust, T.record(model), local: true]) do
          statements = block.body&.body || []
          unsupported!(node, "an empty map block") if statements.empty?
          statements[0...-1].each { statement(_1) }
          value(statements.last)
        end
        element = value.type.nilable? ? value.type.inner : value.type
        unsupported!(node, "a map block giving #{describe(value.type)}") unless ELEMENTS.include?(element.kind)

        list = fresh("mapped")
        @lines << "let mut #{list} = Vec::with_capacity(#{records.rust}.len());"
        @lines.push("for #{rust} in #{records.rust} {", *lines, "#{list}.push(#{owned(value, value.type)});", "}")
        Code[list, T.list(value.type), :none, hint: list]
      end

      # The one plain parameter a block may take: `|task|`.
      def block_parameter(block, node)
        params = block.is_a?(Prism::BlockNode) && block.parameters.is_a?(Prism::BlockParametersNode) && block.parameters.parameters
        plain = params && params.requireds.size == 1 && params.requireds.first.is_a?(Prism::RequiredParameterNode) &&
                params.optionals.empty? && params.posts.empty? && params.keywords.empty? && !params.rest &&
                !params.keyword_rest && !params.block && block.parameters.locals.empty?
        unsupported!(node, "a #{node.name} block without one plain parameter") unless plain

        params.requireds.first.name.to_s
      end

      # Translates the block body with `name` bound to `code`. Locals it
      # assigns first stay inside it, as in Ruby; a `return` would leave the
      # method, which a Rust loop can't express.
      def in_block(name, code)
        saved = [@lines, @locals.dup, @params.dup, @block]
        @lines = []
        @block = true
        @locals[name] = code
        @params << name
        result = yield
        [@lines, result]
      ensure
        @lines, @locals, @params, @block = saved
      end

      # `render json:` of a mapped list.
      def list_json(code, node)
        inner = code.type.inner
        element = inner.nilable? ? inner.inner : inner
        case element.kind
        when :json
          unsupported!(node, "render json: an array of hashes that may be nil") if inner.nilable?
          @uses.rt("Json")
          Code["Json::Array(#{code.rust})", T::JSON, code.ctx]
        when :record
          unsupported!(node, "render json: an array of records that may be nil") if inner.nilable?
          render_list(code, element.model, node)
        else
          @uses.rt("Json")
          Code["Json::from(#{code.rust})", T::JSON, code.ctx]
        end
      end

      def render_list(code, model, node)
        need_ctx!(node)
        Code["#{as_json(model, nil, node)}.render_all(#{ctx_mut}, &#{code.rust})?", T::JSON, :write]
      end

      # `task.as_json.merge("overdue" => task.overdue?)`: Hash#merge, on a
      # hash as_json or a literal made (those are `object:` Codes).
      def on_json(receiver, node, name, args)
        return nil unless name == "merge"

        unless receiver.extra[:object]
          unsupported!(node, "merge on a value that isn't a hash from as_json or a literal")
        end
        arg = only(args, node)
        other = hash?(arg) ? json_literal(arg) : expr(arg)
        unsupported!(node, "merge with #{describe(other.type)}") unless other.type == T::JSON && other.extra[:object]
        receiver, other = settle([receiver, other], :none)
        @uses.rt("merge")
        Code["merge(#{receiver.rust}, #{other.rust})", T::JSON, touch(receiver, other), object: true]
      end
    end
  end
end
