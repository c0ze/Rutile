module Rutile
  module Build
    # A block's parameter and body (the loops are Iteration's), rendering
    # the arrays blocks give, and `merge` on a hash `as_json` made.
    module Blocks
      # What a mapped list may hold.
      ELEMENTS = %i[json str int float bool record].freeze

      private

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
        if name
          @locals[name] = code
          @params << name
        end
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
          Code["Json::Array(#{owned(code)})", T::JSON, code.ctx]
        when :record
          unsupported!(node, "render json: an array of records that may be nil") if inner.nilable?
          render_list(code, element.model, node)
        when :float
          # serde_json writes 1e20 where Ruby's JSON writes 1.0e+20.
          unsupported!(node, "render json: an array of Floats")
        else
          @uses.rt("Json")
          Code["Json::from(#{owned(code)})", T::JSON, code.ctx]
        end
      end

      def render_list(code, model, node)
        need_ctx!(node)
        Code["#{as_json(model, nil, node)}.render_all(#{ctx_mut}, &#{code.rust})?", T::JSON, :write]
      end

      # `task.as_json.merge("overdue" => task.overdue?)`: Hash#merge, on a
      # hash as_json or a literal made. Those Codes carry their `keys`, each
      # a String or a Symbol: Ruby keeps "title" and :title apart, and the
      # JSON encoder then raises on the duplicate, so merging one onto the
      # other is refused. The argument runs after the receiver, as in Ruby.
      def on_json(receiver, node, name, args)
        return nil unless name == "merge"

        keys = receiver.extra[:keys] or unsupported!(node, "merge on a value that isn't a hash from as_json or a literal")
        arg = only(args, node)
        receiver, other = after(receiver) { hash?(arg) ? json_literal(arg) : expr(arg) }
        added = other.extra[:keys]
        unsupported!(node, "merge with #{describe(other.type)}") unless other.type == T::JSON && added
        added.each do |key, kind|
          next if [nil, kind].include?(keys[key])

          unsupported!(node, "merge with the #{kind} key #{key}, which the hash already has as a #{keys[key]},")
        end
        receiver, other = settle([receiver, other], :none)
        @uses.rt("merge")
        Code["merge(#{receiver.rust}, #{other.rust})", T::JSON, touch(receiver, other), keys: keys.merge(added)]
      end
    end
  end
end
