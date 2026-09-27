module Rutile
  module Build
    # Ruby's everyday operators. Each keeps Ruby's meaning or is refused.
    module Expressions
      COMPARE = %w[== != < <= > >=].freeze
      ORDERED = %i[int float str time date].freeze
      ARITHMETIC = %w[+ - * / %].freeze
      # How tightly Rust binds each operator.
      BINDS = { "+" => 1, "-" => 1, "*" => 2, "/" => 2, "%" => 2 }.freeze
      # Ruby's floor division and modulo, which Rust's operators aren't.
      FLOORED = { ["/", :int] => "div_integers", ["%", :int] => "mod_integers", ["%", :float] => "mod_floats" }.freeze

      private

      # `x&.m`: nil stays nil, otherwise `m` runs on the value.
      def safe_call(receiver, node, name, args)
        return send_to(receiver, node, name, args) unless receiver.type.nilable?

        receiver = bind(receiver) if receiver.reads? || impure?(receiver)
        var = @locals.key?(receiver.hint) || receiver.hint.nil? ? fresh("value") : receiver.hint
        saved = @lines
        @lines = []
        inner = send_to(Code[var, receiver.type.inner, hint: receiver.hint], node, name, args)
        unsupported!(node, "&. on a call that needs statements") unless @lines.empty?
        unsupported!(node, "&. on a call that writes") if inner.writes? || inner.rust.include?("?")
        @lines = saved
        # Onto something that may itself be nil, it stays one Option deep.
        flat = inner.type.nilable?
        rust = "#{receiver.rust}.#{flat ? "and_then" : "map"}(|#{var}| #{inner.rust})"
        safe = inner.type == T::BOOL ? { safe: [receiver.rust, var, inner.rust] } : {}
        Code[rust, flat ? inner.type : T.nilable(inner.type), :read, nav: true, **safe]
      end

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

      # Ruby makes a Bignum past 64 bits.
      def integer_literal(node)
        unsupported!(node, "an integer past 64 bits") unless node.value.between?(-2**63, 2**63 - 1)

        Code[node.value.to_s, T::INT]
      end

      # A Float literal as Rust spells it: Ruby's `to_s` of one always has
      # a `.` or an exponent, which Rust reads the same.
      def float_literal(node)
        unsupported!(node, "a Float literal too large for a Float") unless node.value.finite?

        Code[node.value.to_s, T::FLOAT]
      end

      def negate(receiver, node) = Code["!(#{truthy(receiver, node)})", T::BOOL, receiver.ctx]

      # `==` and `!=` compare like types (an Option with its value); the
      # ordering operators raise on nil, as Ruby's NoMethodError does.
      # Both sides in Ruby's order: the left is read before the right's
      # statements run.
      def compare(node, name, arg)
        left, right = in_order([node.receiver, arg]) { value(_1) }
        ctx = touch(left, right)
        rust = if [left, right].any? { _1.type == T::VALUE }
                 dynamic_compare(node, name, left, right)
               elsif [left, right].any? { _1.type == T::NIL }
                 nil_compare(left, right, name, node)
               elsif %w[== !=].include?(name) && record?(left) && record?(right)
                 ctx = :read if ctx == :none
                 same_record(left, right, name, node)
               elsif %w[== !=].include?(name)
                 equality(left, right, name, node)
               else
                 # Ruby can't order a Symbol against a String at all.
                 unsupported!(node, "#{name} between a string and a symbol") if !left.extra[:symbol] != !right.extra[:symbol]
                 left = unwrap(left, name)
                 right = unwrap(right, name)
                 unless left.type == right.type && ORDERED.include?(left.type.kind)
                   unsupported!(node, "#{name} between #{describe(left.type)} and #{describe(right.type)}")
                 end
                 left, right = settle([left, right], :none)
                 "#{group(left.rust, left)} #{name} #{group(right.rust, right)}"
               end
        Code[rust, T::BOOL, ctx, compared: true]
      end

      def record?(code) = (code.type.nilable? ? code.type.inner : code.type).kind == :record

      # Active Record's `==` compares ids: the same row loaded twice is two
      # handles, so `@task.assignee == current_user` can't compare them.
      def same_record(left, right, name, node)
        need_ctx!(node)
        l, r = [left, right].map { (_1.type.nilable? ? _1.type.inner : _1.type).model }
        unsupported!(node, "#{name} between #{describe(left.type)} and #{describe(right.type)}") unless l == r
        left, right = settle([left, right], :read)
        "#{"!" if name == "!="}#{ctx_recv}.same_record(#{left.rust}, #{right.rust})"
      end

      def nil_compare(left, right, name, node)
        unsupported!(node, "#{name} with nil") unless %w[== !=].include?(name)
        return name == "==" ? "true" : "false" if left.type == T::NIL && right.type == T::NIL

        value = left.type == T::NIL ? right : left
        unsupported!(node, "#{name} nil on a value that's never nil") unless value.type.nilable?

        "#{value.rust}.#{name == "==" ? "is_none" : "is_some"}()"
      end

      # `a + b`, `a - b`, `a * b`, `a / b`, `a % b` on Integers and Floats;
      # an Integer with a Float is a Float, as Ruby coerces it. Ruby
      # promotes an overflowing Integer to a Bignum; generated crates build
      # with overflow-checks, so Rust panics (a 500) instead of wrapping.
      # `/` and `%` round toward negative infinity and raise on zero, as
      # Ruby's do. A nil operand raises, as it does in Ruby; a Value
      # dispatches at run time.
      def arithmetic(node, name, arg) = combine(node, name, *in_order([node.receiver, arg]) { value(_1) })

      def combine(node, name, left, right)
        return dynamic_arithmetic(node, name, left, right) if [left, right].any? { _1.type == T::VALUE }

        left, right = [left, right].map { unwrap(_1, name) }
        kinds = [left.type.kind, right.type.kind]
        if name == "+" && kinds == %i[str str]
          # Symbol has no +, and String#+ won't take one.
          unsupported!(node, "+ with a Symbol") if [left, right].any? { _1.extra[:symbol] }
          left, right = settle([left, right], :none)
          return Code["format!(\"{}{}\", #{left.rust}, #{right.rust})", T::STR, touch(left, right)]
        end
        unsupported!(node, "#{name} between #{describe(left.type)} and #{describe(right.type)}") unless (kinds - %i[int float]).empty?
        left, right = [left, right].map do
          kinds.include?(:float) && _1.type == T::INT ? Code["(#{_1.rust} as f64)", T::FLOAT, _1.ctx, cast: "#{_1.rust} as f64"] : _1
        end
        left, right = settle([left, right], :none)
        if (function = FLOORED[[name, left.type.kind]])
          @uses.rt(function)
          # An argument needs no parentheses; Rust warns about them.
          bare = ->(code) { code.extra[:cast] && code.rust == "(#{code.extra[:cast]})" ? code.extra[:cast] : code.rust }
          return Code["#{function}(#{bare.(left)}, #{bare.(right)})?", left.type, touch(left, right)]
        end
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

      # `rust` as the receiver of a method call, which binds tighter than
      # an operator or an `if`.
      def atom(rust, code) = code.extra[:arith] || rust.start_with?("if ") ? "(#{rust})" : rust

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

      # `"%#{query}%"`: format!, for the types whose Display is Ruby's
      # to_s: String, Integer, true and false.
      def interpolation(node)
        unless node.parts.all? { _1.is_a?(Prism::StringNode) || _1.is_a?(Prism::EmbeddedStatementsNode) }
          unsupported!(node, "interpolating a variable without braces")
        end
        embedded = node.parts.grep(Prism::EmbeddedStatementsNode)
        codes = in_order(embedded) { value(only(_1.statements&.body || [], _1)) }
        codes.zip(embedded).each do |code, part|
          unless [T::STR, T::INT, T::BOOL, T::VALUE].include?(code.type) || [T::STR, T::INT].map { T.nilable(_1) }.include?(code.type)
            unsupported!(part, "interpolating #{describe(code.type)}")
          end
        end
        # nil interpolates as "", as its to_s is.
        codes = settle(codes, :none).map do |code|
          case code.type
          when T::VALUE then Code["#{code.rust}.to_s()", T::STR, code.ctx]
          when T.nilable(T::STR) then Code["#{code.rust}.as_deref().unwrap_or_default()", T::STR, code.ctx]
          when T.nilable(T::INT) then Code["#{code.rust}.map(|value| value.to_string()).unwrap_or_default()", T::STR, code.ctx]
          else code
          end
        end
        template = node.parts.map { _1.is_a?(Prism::StringNode) ? _1.unescaped.gsub(/[{}]/) { |b| b * 2 } : "{}" }.join
        Code["format!(#{Names.str(template)}#{codes.map { ", #{_1.rust}" }.join})", T::STR, touch(*codes)]
      end

      def equality(left, right, name, node)
        # Attributes, enums included, and params are Strings in Ruby; a
        # Symbol never equals one.
        if !left.extra[:symbol] != !right.extra[:symbol]
          unsupported!(node, "#{name} between a string and a symbol")
        end
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
        # `urgent ? :high : :low` is a Symbol, which a String never equals.
        unsupported!(node, "an if whose branches have different types") if !a.extra[:symbol] != !b.extra[:symbol]
        rust = "if #{condition} {\n#{[*then_lines, a_rust].join("\n")}\n} else {\n#{[*else_lines, b_rust].join("\n")}\n}"
        Code[rust, type, touch(test, a, b), symbol: a.extra[:symbol]]
      end

      def unify(a, b, node)
        return [a.type, owned(a, a.type), owned(b, b.type)] if a.type == b.type
        # A Value holds nil itself; an Option of one would count nil as there.
        return [T::VALUE, *[a, b].map { owned(to_value(_1), T::VALUE) }] if [a.type, b.type].sort_by(&:kind) == [T::NIL, T::VALUE].sort_by(&:kind)
        return [T.nilable(b.type), "None", "Some(#{owned(b, b.type)})"] if a.type == T::NIL && !b.type.nilable?
        return [T.nilable(a.type), "Some(#{owned(a, a.type)})", "None"] if b.type == T::NIL && !a.type.nilable?
        return [a.type, owned(a), "None"] if b.type == T::NIL
        return [b.type, "None", owned(b)] if a.type == T::NIL
        return [a.type, owned(a), "Some(#{owned(b, b.type)})"] if a.type == T.nilable(b.type)
        return [b.type, "Some(#{owned(a, a.type)})", owned(b)] if b.type == T.nilable(a.type)
        return dynamic_unify(a, b, node) if scalar?(a.type) && scalar?(b.type)

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
