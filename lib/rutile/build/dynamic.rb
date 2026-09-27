module Rutile
  module Build
    # The `Value` fallback (design.md, Types layer 4). Where no static type
    # reaches a value (a param, an `untyped` signature, a local given values
    # of different classes, an `if` whose branches differ), it's a
    # `rustonrails::Value`, and Ruby's operators dispatch on its class at
    # run time, with Ruby's results and errors. Each place is reported, so a
    # signature can go where the speed matters.
    module Dynamic
      # What a Value holds, as Rutile types them.
      SCALARS = [T::NIL, T::BOOL, T::INT, T::FLOAT, T::STR, T::TIME, T::DATE, T::VALUE].freeze
      # Value's method for each operator.
      OPERATORS = { "+" => "add", "-" => "sub", "*" => "mul", "/" => "div", "%" => "modulo" }.freeze

      # Translating again with a local as a Value, or with what the method
      # returns (a Value unless `returns` says).
      class Retype < StandardError
        attr_reader :local, :returns, :node

        def initialize(local = nil, node:, returns: nil)
          @local = local
          @returns = returns
          @node = node
          super("retype #{local || "the returned value"}")
        end
      end

      private

      def scalar?(type) = SCALARS.include?(type) || (type.nilable? && SCALARS.include?(type.inner))

      # `code` as a Value; nil for a type a Value can't hold, or a Symbol,
      # which a Value would hold as a String.
      def to_value(code)
        return code if code.type == T::VALUE
        return nil unless scalar?(code.type) && !code.extra[:symbol]

        @uses.rt("Value")
        return Code["Value::Nil", T::VALUE] if code.type == T::NIL

        Code["Value::from(#{owned(code, code.type)})", T::VALUE, code.ctx, hint: code.hint]
      end

      def fallback!(node, what) = @app.fallback(@path, node, "#{what} falls back to Value")

      # The body, translated again each time a local or its value turns
      # out to need a Value. Whatever the attempt before collected is
      # dropped, so it leaves no stray imports or names; a controller
      # forgets the helpers and instance variables it translated too.
      # Each attempt retypes a local or widens the returned type, so there
      # are only so many.
      def retyped
        saved = [@locals.dup, @params.dup, @taken.dup, @renames.dup, @uses.snapshot]
        checkpoint = @controller.checkpoint if @controller.respond_to?(:checkpoint)
        attempts = 0
        begin
          yield
        rescue Retype => e
          unsupported!(e.node, "a value whose type keeps changing") if (attempts += 1) > @writes.size + 4

          @locals, @params, @taken, @renames = saved[0..3].map(&:dup)
          @uses.restore(saved[4])
          @controller.rollback(checkpoint) if checkpoint
          if e.local
            (@dynamic ||= Set.new) << e.local
          else
            @returns = e.returns || T::VALUE
            @inferred = true
          end
          retry
        end
      end

      # A method without a signature returning early: the first value it
      # returns is its type to begin with.
      def infer_returns!(node)
        code = node.arguments ? value(only(node.arguments.arguments, node)) : Code["None", T::NIL]
        unsupported!(node, "returning a Symbol") if code.extra[:symbol]
        raise Retype.new(returns: code.type, node:)
      end

      # A value the method returns that its inferred type doesn't take: nil
      # and a value make an Option of it; two classes of scalar, a Value.
      def refine_returns!(want, code, node)
        inner = ->(type) { type.nilable? ? type.inner : type }
        types = [want, code.type].reject { _1 == T::NIL }
        if types.map(&inner).uniq.size == 1 && inner.(types.first) != T::VALUE
          raise Retype.new(returns: T.nilable(inner.(types.first)), node:)
        end
        return unless scalar?(want) && scalar?(code.type)
        # A Value holds nil too: it's never an Option.
        raise Retype.new(returns: T::VALUE, node:) if types.map(&inner) == [T::VALUE]

        fallback!(node, "the value, #{classes(want, code.type)},")
        raise Retype.new(returns: T::VALUE, node:)
      end

      # A local assigned values of different classes is a Value from its
      # first assignment; anything else keeps its one type.
      def retype!(name, known, code, node)
        unless scalar?(known.type) && scalar?(code.type) && !@dynamic&.include?(name)
          unsupported!(node, code.type == T::NIL && known.equal?(code) ? "a local assigned nil" : "giving #{name} a new type")
        end
        # A Value would hold a Symbol as a String, which no Symbol equals.
        unsupported!(node, "a Symbol in #{name}, which is assigned again") if [known, code].any? { _1.extra[:symbol] }

        fallback!(node, "#{name}, assigned #{classes(known.type, code.type, joiner: "and")},")
        raise Retype.new(name, node:)
      end

      def local_value(name, code) = @dynamic&.include?(name) ? (to_value(code) || code) : code

      # The value a method or helper ends on, when its branches differ.
      def retype_returns!(node, a, b)
        # A block's value isn't what the method returns.
        unsupported!(node, "an if whose branches return different types") unless @returns.nil? && @mode == :value && !@block
        refine_returns!(a, Code["", b], node) if [a, b].include?(T::NIL) || [a, b].any?(&:nilable?)
        unsupported!(node, "an if whose branches return different types") unless scalar?(a) && scalar?(b)

        fallback!(node, "the value, #{classes(a, b)},")
        raise Retype.new(node:)
      end

      # `a + b` and the rest with a Value on either side.
      def dynamic_arithmetic(node, name, left, right)
        left, right = [left, right].map { to_value(_1) || unsupported!(node, "#{name} between #{describe(left.type)} and #{describe(right.type)}") }
        left, right = settle([left, right], :none)
        fallback!(node, name)
        Code["#{left.rust}.#{OPERATORS.fetch(name)}(&#{right.rust})?", T::VALUE, touch(left, right)]
      end

      # `==` and the ordering operators with a Value on either side.
      def dynamic_compare(node, name, left, right)
        # Ordering against nil raises, as Ruby's does; only == and != test it.
        if %w[== !=].include?(name) && [left, right].any? { _1.type == T::NIL }
          value = left.type == T::NIL ? right : left
          return "#{name == "==" ? "" : "!"}#{value.rust}.is_nil()"
        end
        left, right = [left, right].map { to_value(_1) || unsupported!(node, "#{name} between #{describe(left.type)} and #{describe(right.type)}") }
        left, right = settle([left, right], :none)
        fallback!(node, name)
        case name
        when "==" then "#{left.rust}.equals(&#{right.rust})"
        when "!=" then "!#{left.rust}.equals(&#{right.rust})"
        else "#{left.rust}.compare(#{Names.str(name)}, &#{right.rust})?"
        end
      end

      # `if c then a else b end` as a value, with branches of two classes.
      def dynamic_unify(a, b, node)
        values = [a, b].map { to_value(_1) }
        unsupported!(node, "an if whose branches have different types") if values.any?(&:nil?)

        fallback!(node, "the if's value, #{classes(a.type, b.type)},") unless [a.type, b.type].include?(T::VALUE)
        [T::VALUE, *values.map { owned(_1, T::VALUE) }]
      end

      # `types` as the classes they hold: "int, str or nil".
      def classes(*types, joiner: "or")
        names = types.flat_map { _1.nilable? ? [_1.inner, T::NIL] : [_1] }.uniq.map { describe(_1) }
        names.size > 1 ? "#{names[0..-2].join(", ")} #{joiner} #{names.last}" : names.first
      end
    end
  end
end
