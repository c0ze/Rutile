module Rutile
  module Build
    # `transaction do ... end` in app code, and `raise ActiveRecord::Rollback`.
    # The block becomes a closure the runtime calls inside the transaction:
    # it commits when the block ends; Rollback rolls back and the block
    # gives nil; any other error rolls back and goes on up. Inside another
    # transaction it joins that one, as Active Record's does.
    module Transactions
      # Classes whose `transaction` is Active Record's, besides the models.
      CLASSES = %w[ActiveRecord::Base ApplicationRecord].freeze
      ROLLBACK = "ActiveRecord::Rollback"

      private

      def transaction(node, value:)
        need_ctx!(node)
        transaction_receiver!(node)
        unsupported!(node, "transaction with options") if node.arguments
        unless node.block.is_a?(Prism::BlockNode) && node.block.parameters.nil?
          unsupported!(node, "a transaction block that takes a parameter")
        end
        statements = block_statements(node.block, node)
        unsupported!(node, "an empty transaction block") if statements.empty?
        lines, type = closure_body(statements, value)
        req = @env == :model ? "ctx" : "req"
        # A block that only raises leaves Rust nothing to infer its type from.
        head = "#{req}.transaction_block#{"::<()>" if rollback?(statements.last)}(|#{req}| {"
        unless value
          @lines.push(head, *lines, *("Ok(())" unless rollback?(statements.last)), "})?;")
          return
        end
        unsupported!(node, "render inside a transaction block") if type == T::RESPONSE
        unsupported!(node, "using the value of a transaction block that ends in #{describe(type)}") if [T::UNIT, T::NIL].include?(type)
        rust = [head, *lines, "})?#{".flatten()" if type.nilable?}"].join("\n")
        Code[rust, type.nilable? ? type : T.nilable(type), :write, hint: "transaction"]
      end

      # The block's statements, translated for a closure: a `return` would
      # leave only the closure, so it's refused as in any block, and a
      # signature's return type doesn't apply to the block's value.
      def closure_body(statements, value)
        saved = [@returns, @block]
        @returns = nil
        @block = true
        block(statements, value ? :value : :unit)
      ensure
        @returns, @block = saved
      end

      # A model's own `transaction`, a model class's, ApplicationRecord's
      # or ActiveRecord::Base's: all the same connection's.
      def transaction_receiver!(node)
        receiver = node.receiver
        ok = case receiver
             when nil, Prism::SelfNode then @env == :model
             when Prism::ConstantReadNode, Prism::ConstantPathNode
               CLASSES.include?(constant_path(receiver)) || @app.model?(constant_path(receiver))
             else false
             end
        unsupported!(node, "transaction on #{receiver ? receiver.slice : "self"}") unless ok
      end

      # `raise ActiveRecord::Rollback`, as a statement.
      def raise_statement(node)
        args = node.arguments&.arguments || []
        unless args.size == 1 && constant_path(args.first) == ROLLBACK
          unsupported!(node, "raise, except raise ActiveRecord::Rollback,")
        end
        unsupported!(node, "raise here") unless @result
        @uses.rt("Error")
        @lines << "return Err(Error::Rollback);"
      end

      def rollback?(node)
        node.is_a?(Prism::CallNode) && node.name == :raise && node.receiver.nil? &&
          constant_path(node.arguments&.arguments&.first) == ROLLBACK
      end

      def constant_path(node)
        node.full_name.delete_prefix("::") if node.is_a?(Prism::ConstantReadNode) || node.is_a?(Prism::ConstantPathNode)
      end
    end
  end
end
