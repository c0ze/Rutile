module Rutile
  module Build
    # Ruby's everyday operators. Each keeps Ruby's meaning or is refused.
    module Expressions
      COMPARE = %w[== != < <= > >=].freeze
      ORDERED = %i[int float str time].freeze
      ARITHMETIC = %w[+ - *].freeze
      # How tightly Rust binds each operator.
      BINDS = { "+" => 1, "-" => 1, "*" => 2 }.freeze

      private

      # `a && b`, `a || b`: Rust's operators short-circuit as Ruby's do, and
      # statements the right side needs go in a block so they run only when
      # it does. Ruby returns an operand; unless both are booleans, only the
      # result's truth is compiled (T::COND).
      def logic(node)
        left = expr(node.left)
        lines, right = capture { expr(node.right) }
        right_rust = group(truthy(right, node.right), right, logic: true)
        right_rust = "{\n#{lines.join("\n")}\n#{right_rust}\n}" unless lines.empty?
        operator = node.is_a?(Prism::AndNode) ? "&&" : "||"
        type = left.type == T::BOOL && right.type == T::BOOL ? T::BOOL : T::COND
        Code["#{group(truthy(left, node.left), left, logic: true)} #{operator} #{right_rust}", type, touch(left, right), logic: true]
      end

      def negate(receiver, node) = Code["!(#{truthy(receiver, node)})", T::BOOL, receiver.ctx]

      # `==` and `!=` compare like types (an Option with its value); the
      # ordering operators raise on nil, as Ruby's NoMethodError does.
      # Both sides in Ruby's order: the left is read before the right's
      # statements run.
      def compare(node, name, arg)
        left, right = in_order([node.receiver, arg]) { value(_1) }
        rust = if [left, right].any? { _1.type == T::NIL }
                 nil_compare(left, right, name, node)
               elsif %w[== !=].include?(name)
                 equality(left, right, name, node)
               else
                 left = unwrap(left, name)
                 right = unwrap(right, name)
                 unless left.type == right.type && ORDERED.include?(left.type.kind)
                   unsupported!(node, "#{name} between #{describe(left.type)} and #{describe(right.type)}")
                 end
                 left, right = settle([left, right], :none)
                 "#{group(left.rust, left)} #{name} #{group(right.rust, right)}"
               end
        Code[rust, T::BOOL, touch(left, right), compared: true]
      end

      def nil_compare(left, right, name, node)
        unsupported!(node, "#{name} with nil") unless %w[== !=].include?(name)
        return name == "==" ? "true" : "false" if left.type == T::NIL && right.type == T::NIL

        value = left.type == T::NIL ? right : left
        unsupported!(node, "#{name} nil on a value that's never nil") unless value.type.nilable?

        "#{value.rust}.#{name == "==" ? "is_none" : "is_some"}()"
      end

      # `a + b`, `a - b`, `a * b` on two Integers or two Floats. Ruby
      # promotes an overflowing Integer to a Bignum; generated crates build
      # with overflow-checks, so Rust panics (a 500) instead of wrapping.
      # A nil operand raises, as it does in Ruby.
      def arithmetic(node, name, arg)
        left, right = in_order([node.receiver, arg]) { value(_1) }.map { unwrap(_1, name) }
        unless left.type == right.type && %i[int float].include?(left.type.kind)
          unsupported!(node, "#{name} between #{describe(left.type)} and #{describe(right.type)}")
        end
        left, right = settle([left, right], :none)
        rust = "#{operand(left, name, false)} #{name} #{operand(right, name, true)}"
        Code[rust, left.type, touch(left, right), arith: name]
      end

      # Parentheses where Rust would regroup: a looser operator inside a
      # tighter one, an equal one on the right (`a - (b - c)`), an `if`.
      def operand(code, name, right)
        inner = code.extra[:arith]
        loose = inner && (BINDS[inner] < BINDS[name] || (right && BINDS[inner] == BINDS[name]))
        loose || code.rust.start_with?("if ") ? "(#{code.rust})" : code.rust
      end

      # `[a, b].max`: Integers only; Ruby raises comparing nil.
      def extremum(node, name)
        elements = node.receiver.elements
        unsupported!(node, "#{name} of an empty array") if elements.empty?
        codes = in_order(elements) { value(_1) }
        unless codes.all? { _1.type == T::INT }
          unsupported!(node, "#{name} over #{codes.map { describe(_1.type) }.uniq.join(" and ")}")
        end
        codes = settle(codes, :none)
        Code[codes.map(&:rust).reduce { |a, b| "i64::#{name}(#{a}, #{b})" }, T::INT, touch(*codes)]
      end

      def equality(left, right, name, node)
        left, right = settle([left, right], :none)
        l = left.type.nilable? ? left.type.inner : left.type
        r = right.type.nilable? ? right.type.inner : right.type
        unsupported!(node, "#{name} between #{describe(left.type)} and #{describe(right.type)}") unless l == r
        a, b = [left, right].map { group(side(_1, [left, right].any? { |c| c.type.nilable? }), _1) }
        "#{a} #{name} #{b}"
      end

      # One side of an equality, as an Option when the other side is one.
      def side(code, optional)
        return code.rust unless optional
        return (code.type.inner == T::STR ? "#{code.rust}.as_deref()" : code.rust) if code.type.nilable?

        code.extra[:literal] || code.type != T::STR ? "Some(#{code.rust})" : "Some(#{code.rust}.as_str())"
      end

      def unwrap(code, name)
        return code unless code.type.nilable?

        @uses.rt("Error")
        Code["#{code.rust}.ok_or(Error::Nil { what: #{Names.str(name)} })?", code.type.inner, code.ctx, hint: code.hint]
      end

      # `c ? a : b` (and `if c then a else b end` used as a value).
      def ternary(node)
        unsupported!(node, "elsif") if node.subsequent.is_a?(Prism::IfNode)
        unsupported!(node, "an if without else used as a value") unless node.subsequent

        test = expr(node.predicate)
        condition = truthy(test, node.predicate)
        then_lines, a = capture { expr(only(node.statements&.body || [], node)) }
        else_lines, b = capture { expr(only(node.subsequent.statements&.body || [], node)) }
        type, a_rust, b_rust = unify(a, b, node)
        rust = "if #{condition} {\n#{[*then_lines, a_rust].join("\n")}\n} else {\n#{[*else_lines, b_rust].join("\n")}\n}"
        Code[rust, type, touch(test, a, b)]
      end

      def unify(a, b, node)
        return [a.type, owned(a, a.type), owned(b, b.type)] if a.type == b.type
        return [T.nilable(b.type), "None", "Some(#{owned(b, b.type)})"] if a.type == T::NIL && !b.type.nilable?
        return [T.nilable(a.type), "Some(#{owned(a, a.type)})", "None"] if b.type == T::NIL && !a.type.nilable?
        return [a.type, owned(a), "None"] if b.type == T::NIL
        return [b.type, "None", owned(b)] if a.type == T::NIL

        unsupported!(node, "an if whose branches have different types")
      end

      # An operand keeps its own grouping: `a && (b || c)`, and a comparison
      # of comparisons, which Rust won't chain. A comparison inside && or ||
      # needs no parentheses.
      def group(rust, code, logic: false)
        needs = code.extra[:logic] || (!logic && code.extra[:compared])
        needs ? "(#{rust})" : rust
      end

      def capture
        saved = @lines
        @lines = []
        result = yield
        [@lines, result]
      ensure
        @lines = saved
      end

      def touch(*codes)
        return :write if codes.any?(&:writes?)

        codes.any?(&:reads?) ? :read : :none
      end
    end
  end
end
