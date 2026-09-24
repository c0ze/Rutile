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
        unsupported!(node, "an if whose branches return different types") unless else_type == type
        @lines.push("if #{condition} {", *then_lines, "} else {", *else_lines, "}")
        type
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

      # `return` in a callback or a filter; a value to return isn't compiled.
      def early_return(node)
        unsupported!(node, "return inside a block") if @block
        unsupported!(node, "return with a value") if node.arguments
        case @mode
        when :unit then @lines << (@result ? "return Ok(());" : "return;")
        when :filter then @lines << "return Ok(None);"
        else unsupported!(node, "return here")
        end
      end
    end
  end
end
