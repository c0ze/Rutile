module Rutile
  module Build
    # The translator's bookkeeping: truthiness, binding values to locals so
    # the borrow checker and Ruby's evaluation order are both satisfied, how
    # the Ctx is spelled, and reading call arguments.
    module Borrowing
      private

      def truthy(code, node)
        type = code.type
        return code.rust if type == T::BOOL || type == T::COND
        return "false" if type == T::NIL
        unsupported!(node, "a condition on #{describe(type)}") unless type.nilable?
        return "#{code.rust}.is_some()" unless type.inner == T::BOOL

        receiver, var, body = code.extra[:safe]
        receiver ? "#{receiver}.is_some_and(|#{var}| #{body})" : "#{code.rust} == Some(true)"
      end

      # An expression used as a value. `&&` and `||` of non-booleans compile
      # to their truth only, so their value can't be used.
      def value(node)
        code = expr(node)
        unsupported!(node, "using the value of && or ||") if code.type == T::COND
        code
      end

      # Binds `code` to a fresh local named after its hint.
      def bind(code)
        name = fresh(code.hint || "value")
        @lines << "let #{name} = #{code.rust};"
        Code[name, code.type, hint: code.hint, **code.extra.except(:literal, :local, :safe, :nav)]
      end

      def fresh(hint)
        name = hint
        n = 1
        name = "#{hint}_#{n += 1}" while @taken.include?(name)
        @taken << name
        name
      end

      # Around a call that writes the Ctx, anything else touching it must be
      # a local already; around one that reads it, anything writing it must.
      # With no Ctx use of its own, a call still can't hold two writers.
      def settle(codes, parent)
        touching = codes.count(&:reads?)
        codes.map do |code|
          must = case parent
                 when :write then code.reads?
                 when :read then code.writes?
                 else code.writes? && touching > 1
                 end
          must ? bind(code) : code
        end
      end

      # Translates `nodes` left to right. Before one that runs statements or
      # writes the Ctx, the earlier ones that read it become locals, so they
      # see the state Ruby would.
      def in_order(nodes)
        nodes.each_with_object([]) do |node, codes|
          mark = @lines.size
          code = yield(node)
          if code.writes? || @lines.size > mark
            codes.each_index.select { codes[_1].reads? }.each_with_index do |i, n|
              name = fresh(codes[i].hint || "value")
              @lines.insert(mark + n, "let #{name} = #{codes[i].rust};")
              codes[i] = Code[name, codes[i].type, hint: codes[i].hint]
            end
          end
          codes << code
        end
      end

      # Evaluates what Ruby evaluates after `receiver`, a call's arguments.
      # If that ran statements or writes the Ctx, the receiver becomes a
      # local first, so it reads the Ctx before they run. Returns the
      # receiver and the block's result, whose Codes are checked for writes.
      def after(receiver)
        mark = @lines.size
        result = yield
        writes = [result].flatten.any? { _1.is_a?(Code) && _1.writes? }
        return [receiver, result] unless receiver.reads? && (writes || @lines.size > mark)

        name = fresh(receiver.hint || "value")
        @lines.insert(mark, "let #{name} = #{receiver.rust};")
        [Code[name, receiver.type, hint: receiver.hint, **receiver.extra.except(:literal, :local, :safe, :nav)], result]
      end

      # Fallible (`?`) or writing: running it later, or twice, would differ.
      def impure?(code) = code.writes? || code.rust.include?("?")

      # Literals can't observe or change anything.
      def literal?(node)
        case node
        when Prism::SymbolNode, Prism::StringNode, Prism::IntegerNode, Prism::FloatNode, Prism::TrueNode, Prism::FalseNode,
             Prism::NilNode
          true
        when Prism::ArrayNode then node.elements.all? { literal?(_1) }
        when Prism::HashNode, Prism::KeywordHashNode
          node.elements.all? { _1.is_a?(Prism::AssocNode) && literal?(_1.key) && literal?(_1.value) }
        else false
        end
      end

      # A plain name already, or bound to one.
      def local!(code) = code.rust.match?(/\A[a-z_][a-z0-9_]*\z/) ? code : bind(code)

      # The value itself: a literal where a String is wanted, and a clone of
      # a non-Copy local, which Ruby may read again.
      def owned(code, want = nil)
        return "#{code.rust}.to_string()" if code.extra[:literal] && want == T::STR
        return "#{code.rust}.clone()" if code.extra[:local] && !code.extra[:literal] && !code.type.copy?

        code.rust
      end

      # How the Ctx is spelled: receiver or index, mutable argument, shared argument.
      def ctx_recv = @env == :model ? "ctx" : "req.ctx"
      def ctx_mut = @env == :model ? "ctx" : "&mut req.ctx"
      def ctx_ref = @env == :model ? "ctx" : "&req.ctx"

      def need_ctx!(node) = (%i[model controller].include?(@env) || unsupported!(node, "database access here"))

      # Models are imported, except the one whose file this is.
      def use_model(name) = (@uses.model(name) unless %i[model scope].include?(@env) && name == @model)

      def only(list, node) = list.size == 1 ? list.first : unsupported!(node, "#{list.size} values where one belongs")

      def symbol!(node, at) = node.is_a?(Prism::SymbolNode) ? node.unescaped : unsupported!(at, "a non-symbol argument")

      # `key: value` pairs of a call's hash argument.
      def pairs(args, node)
        hash = only(args, node)
        unsupported!(node, "a non-hash argument") unless hash.is_a?(Prism::KeywordHashNode) || hash.is_a?(Prism::HashNode)
        hash.elements.map do |pair|
          unsupported!(node, "a **splat or a non-symbol key") unless pair.is_a?(Prism::AssocNode) && pair.key.is_a?(Prism::SymbolNode)
          [pair.key.unescaped, pair.value]
        end
      end

      def describe(type)
        case type.kind
        when :record, :class then type.model
        when :relation then "a relation of #{type.model}"
        when :nilable then "#{describe(type.inner)} or nil"
        when :list then "an array of #{describe(type.inner)}"
        when :cond then "the value of && or ||"
        when :record_invalid then "ActiveRecord::RecordInvalid"
        when :invalid_record then "the invalid record"
        else type.kind.to_s.tr("_", " ")
        end
      end

      def unsupported!(node, what) = raise(Unsupported.at(@path, node, what))
    end
  end
end
