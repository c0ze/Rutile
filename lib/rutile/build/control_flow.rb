module Rutile
  module Build
    # if/unless as statements, as an action's or helper's last statement,
    # and as a before_action's last statement.
    module ControlFlow
      private

      def branch(node, tail)
        raise Unsupported.at(@path, node, "elsif") if node.subsequent.is_a?(Prism::IfNode)

        condition = truthy(expr(node.predicate), node.predicate)
        then_lines, type = block(node.statements&.body || [], tail)
        else_lines, else_type = block(node.subsequent.statements&.body || [], tail)
        retype_returns!(node, type, else_type) unless else_type == type
        @lines.push("if #{condition} {", *then_lines, "} else {", *else_lines, "}")
        type
      end

      # `total += price`: as `total = total + price` would be, for the
      # arithmetic operators.
      def operator_assign(node)
        name = node.name.to_s
        operator = node.binary_operator.to_s
        unsupported!(node, "#{operator}=") unless Expressions::ARITHMETIC.include?(operator)
        unsupported!(node, "assigning to the parameter #{name}") if @params.include?(name)
        local = @locals[name] or unsupported!(node, "#{name} #{operator}= before it's assigned")
        result = combine(node, operator, local, value(node.value))
        retype!(name, local, result, node) unless result.type == local.type
        @lines << "#{local.rust} = #{result.rust};"
      end

      def conditional(node)
        other = node.is_a?(Prism::UnlessNode) ? node.else_clause : node.subsequent
        raise Unsupported.at(@path, node, "elsif") if other.is_a?(Prism::IfNode)

        condition = truthy(expr(node.predicate), node.predicate)
        condition = "!(#{condition})" if node.is_a?(Prism::UnlessNode)
        then_lines, = block(node.statements&.body || [], :unit)
        @lines.push("if #{condition} {", *then_lines)
        if other
          else_lines, = block(other.statements&.body || [], :unit)
          @lines.push("} else {", *else_lines)
        end
        @lines << "}"
      end

      # The last statement of a before_action: a render or head there halts
      # the chain (possibly under if/unless); anything else lets it go on.
      def filter_tail(node)
        if node.is_a?(Prism::IfNode) || node.is_a?(Prism::UnlessNode)
          other = node.is_a?(Prism::UnlessNode) ? node.else_clause : node.subsequent
          unsupported!(node, "elsif") if other.is_a?(Prism::IfNode)
          condition = truthy(expr(node.predicate), node.predicate)
          yes, = block(node.statements&.body || [], :filter)
          no, = block(other&.statements&.body || [], :filter)
          yes, no = no, yes if node.is_a?(Prism::UnlessNode)
          @lines.push("if #{condition} {", *yes, "} else {", *no, "}")
        else
          code = expr(node)
          code.type == T::RESPONSE ? @lines << "Ok(Some(#{code.rust}))" : @lines.push("#{code.rust};", "Ok(None)")
        end
        T::UNIT
      end

      # `return` in a callback or a filter, and with or without a value in
      # a method. Without a signature, the first `return` says what the
      # method returns, until another says otherwise (`refine_returns!`).
      def early_return(node)
        unsupported!(node, "return inside a block") if @block
        infer_returns!(node) if @mode == :value && @returns.nil?
        if @mode == :value && @returns
          code = node.arguments ? value(only(node.arguments.arguments, node)) : Code["None", T::NIL]
          code = returned(code, node)
          return @lines << "return Ok(#{owned(code, code.type)});"
        end
        unsupported!(node, "return with a value") if node.arguments
        case @mode
        when :unit then @lines << (@result ? "return Ok(());" : "return;")
        when :filter then @lines << "return Ok(None);"
        else unsupported!(node, "return here")
        end
      end

      # A value the method returns, as the type its signature declares: a
      # value where it may be nil becomes `Some`, and nil `None`.
      def returned(code, node)
        want = @returns
        return code if code.type == want
        return to_value(code) || unsupported!(node, "returning #{describe(code.type)} as a Value") if want == T::VALUE
        return Code["Some(#{owned(code, want.inner)})", want, code.ctx] if want.nilable? && code.type == want.inner
        return Code["None", want] if want.nilable? && code.type == T::NIL
        refine_returns!(want, code, node) if @inferred

        unsupported!(node, "returning #{describe(code.type)} where the signature says #{describe(want)}")
      end
    end
  end
end
