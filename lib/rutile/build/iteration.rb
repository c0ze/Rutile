module Rutile
  module Build
    # Blocks over a relation's records or an array's elements: `each` and
    # `find_each` as statements; `map`, `select`, `filter`, `reject` and
    # `sum` as values. The records load once, and the body runs in a `for`
    # loop rather than a closure, so it can borrow the Ctx and use `?` as
    # the method around it does. A block takes one parameter (`|task|`,
    # `_1` or `it`) or is a method's name (`&:title`).
    module Iteration
      private

      # A call with a block, used as a value.
      def block_call(node, name, args)
        unsupported!(node, "#{name} with a block after &.") if node.safe_navigation?
        return transaction(node, value: true) if name == "transaction"
        unsupported!(node, "using the value of #{name}, which is its receiver,") if %w[each find_each].include?(name)
        unsupported!(node, "a block passed to #{name}") unless node.receiver && %w[map collect select filter reject sum].include?(name)
        return summed(node, args) if name == "sum"

        unsupported!(node, "#{name} with arguments and a block") unless args.empty?
        %w[map collect].include?(name) ? mapped(node) : filtered(node, name)
      end

      # `each`, `find_each`, `transaction` and `raise`, which run as
      # statements; false when `node` is none of them.
      def block_statement(node)
        return false unless node.is_a?(Prism::CallNode)

        name = node.name.to_s
        if name == "raise" && node.receiver.nil? && !node.block
          raise_statement(node)
          return true
        end
        return false unless node.block && !node.safe_navigation? && %w[each find_each transaction].include?(name)

        unsupported!(node, "#{name} without a receiver") if name != "transaction" && node.receiver.nil?
        case name
        when "each" then each_statement(node)
        when "find_each" then find_each(node)
        else transaction(node, value: false)
        end
        true
      end

      def each_statement(node)
        unsupported!(node, "each with arguments") if node.arguments
        iterable, element = elements(node)
        var = loop_variable(node, element)
        lines, = element_body(node, var, element, :unit)
        @lines.push("for #{used(var, lines)} in #{iterable} {", *lines, "}")
      end

      # One query per batch of 1000 (or `batch_size:`), by id.
      def find_each(node)
        size = batch_size(node)
        receiver = relation_receiver(expr(node.receiver), node, "find_each")
        need_ctx!(node)
        receiver = settle([receiver], :write).first
        batches = fresh("batches")
        batch = fresh("batch")
        element = T.record(receiver.type.model)
        var = loop_variable(node, element)
        lines, = element_body(node, var, element, :unit)
        @lines << "let mut #{batches} = #{receiver.rust}.batches(#{size});"
        @lines.push("while let Some(#{batch}) = #{batches}.next(#{ctx_mut})? {", "for #{used(var, lines)} in #{batch} {",
                    *lines, "}", "}")
      end

      def batch_size(node)
        return 1000 unless node.arguments

        options = pairs(node.arguments.arguments, node)
        key, value = options.first
        # Every keyword, not the one hash they arrive in: start: or finish:
        # would narrow the rows Ruby walks.
        unless options.size == 1 && key == "batch_size" && value.is_a?(Prism::IntegerNode) && value.value.between?(1, 2**63 - 1)
          unsupported!(node, "find_each with options other than batch_size: a positive Integer")
        end
        value.value
      end

      def mapped(node)
        iterable, element, sized = elements(node)
        var = loop_variable(node, element)
        lines, value = element_body(node, var, element, :value)
        kind = (value.type.nilable? ? value.type.inner : value.type).kind
        unsupported!(node, "a #{node.name} block giving #{describe(value.type)}") unless Blocks::ELEMENTS.include?(kind)
        unsupported!(node, "a #{node.name} block giving a Symbol, which an array would hold as a String,") if value.extra[:symbol]

        list = fresh("mapped")
        pushed = owned(value, value.type)
        @lines << "let mut #{list} = Vec::with_capacity(#{sized}.len());"
        @lines.push("for #{used(var, [*lines, pushed])} in #{iterable} {", *lines, "#{list}.push(#{pushed});", "}")
        Code[list, T.list(value.type), :none, hint: list]
      end

      # `select` and `filter` keep the elements the block is truthy for;
      # `reject` drops them. On a relation they load its records.
      def filtered(node, name)
        iterable, element = elements(node)
        var = loop_variable(node, element)
        lines, value = element_body(node, var, element, :value)
        condition = truthy(value, node)
        condition = "!(#{condition})" if name == "reject"
        list = fresh(name == "reject" ? "kept" : "selected")
        @lines << "let mut #{list} = Vec::new();"
        @lines.push("for #{var} in #{iterable} {", *lines, "if #{condition} {", "#{list}.push(#{var});", "}", "}")
        Code[list, T.list(element), :none, hint: list]
      end

      # `sum { |x| ... }` is Rails' and Ruby's `map { |x| ... }.sum`.
      def summed(node, args)
        unsupported!(node, "sum with #{args.size} arguments and a block") if args.size > 1
        list_sum(mapped(node), args.first, node)
      end

      # [what the loop runs over, the element type, what has its length]:
      # a relation's records, loaded once, or an array. An array in a local
      # is copied, since Ruby may read it again.
      def elements(node)
        receiver = expr(node.receiver)
        receiver = relation_receiver(receiver, node, node.name) unless receiver.type.kind == :list
        if receiver.type.kind == :relation
          need_ctx!(node)
          receiver = settle([receiver], :write).first
          model = receiver.type.model
          records = bind(Code["#{receiver.rust}.load(#{ctx_mut})?", T.records(model), :write, hint: "records"])
          return [records.rust, T.record(model), records.rust]
        end
        return ["#{receiver.rust}.clone()", receiver.type.inner, receiver.rust] if receiver.extra[:local]

        items = bind(Code[receiver.rust, receiver.type, receiver.ctx, hint: "items"])
        [items.rust, receiver.type.inner, items.rust]
      end

      # A model class iterates as its `all`.
      def relation_receiver(code, node, name)
        if code.type.kind == :class
          @uses.rt("Model")
          code = Code["#{code.type.model}::all()", T.relation(code.type.model), hint: @app.model(code.type.model)["table_name"]]
        end
        code.type.kind == :relation ? code : unsupported!(node, "#{name} on #{describe(code.type)}")
      end

      # The loop's variable: the block's parameter, unless Rust can't take
      # that name, or the block names none.
      def loop_variable(node, element)
        name, = block_form(node)
        hint = element.kind == :record ? Names.snake(element.model) : "item"
        reserved = [*Translator::KEYWORDS, *Names::FUNCTIONS, "ctx", "req", "self", @self_var]
        name.nil? || %w[_1 it].include?(name) || reserved.include?(name) ? fresh(hint) : name
      end

      # The block's body for one element, bound to `var`: [lines, value].
      # `tail` :unit runs every statement for its effect.
      def element_body(node, var, element, tail)
        name, symbol = block_form(node)
        code = Code[var, element, local: true]
        in_block(name, code) do
          if symbol
            called = send_to(code, node, symbol, [])
            next called unless tail == :unit

            @lines << "#{called.rust};" if impure?(called)
          else
            statements = block_statements(node.block, node)
            unsupported!(node, "an empty #{node.name} block") if statements.empty?
            last = tail == :unit ? statements : statements[0...-1]
            last.each { statement(_1) }
            tail == :unit ? nil : value(statements.last)
          end
        end
      end

      # [the parameter's name, nil], [nil, method name] for `&:title`, or
      # [nil, nil] for a block that names no parameter.
      def block_form(node)
        block = node.block
        if block.is_a?(Prism::BlockArgumentNode)
          return [nil, block.expression.unescaped] if block.expression.is_a?(Prism::SymbolNode)

          unsupported!(node, "passing a proc to #{node.name}")
        end
        case block.parameters
        when nil then [nil, nil]
        when Prism::ItParametersNode then ["it", nil]
        when Prism::NumberedParametersNode
          unsupported!(node, "a #{node.name} block using _2") unless block.parameters.maximum == 1
          ["_1", nil]
        else [block_parameter(block, node), nil]
        end
      end

      def block_statements(block, node)
        body = block.body
        unsupported!(node, "rescue or ensure in a #{node.name} block") if body && !body.is_a?(Prism::StatementsNode)
        body&.body || []
      end

      # An unused loop variable starts with `_`, as Rust wants.
      def used(var, lines) = Names.mentions?(lines, var) ? var : "_#{var}"
    end
  end
end
