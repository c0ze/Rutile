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
        attr_reader :local, :returns

        def initialize(local = nil, returns: nil)
          @local = local
          @returns = returns
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
      # dropped, so it leaves no stray imports or names.
      def retyped
        saved = [@locals.dup, @params.dup, @taken.dup, @renames.dup, @uses.snapshot]
        attempts = 0
        begin
          yield
        rescue Retype => e
          raise if (attempts += 1) > 20

          @locals, @params, @taken, @renames = saved[0..3].map(&:dup)
          @uses.restore(saved[4])
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
        raise Retype.new(returns: code.type)
      end

      # A value the method returns that its inferred type doesn't take: nil
      # and a value make an Option of it; two classes of scalar, a Value.
      def refine_returns!(want, code, node)
        inner = ->(type) { type.nilable? ? type.inner : type }
        types = [want, code.type].reject { _1 == T::NIL }
        if types.map(&inner).uniq.size == 1
          raise Retype.new(returns: T.nilable(inner.(types.first)))
        end
        return unless scalar?(want) && scalar?(code.type)

        fallback!(node, "the value, #{describe(want)} or #{describe(code.type)},")
        raise Retype.new(returns: T::VALUE)
      end

      # A local assigned values of different classes is a Value from its
      # first assignment; anything else keeps its one type.
      def retype!(name, known, code, node)
        unless scalar?(known.type) && scalar?(code.type)
          unsupported!(node, code.type == T::NIL ? "a local assigned nil" : "giving #{name} a new type")
        end
        fallback!(node, "#{name}, assigned #{describe(known.type)} and #{describe(code.type)},")
        raise Retype, name
      end

      def local_value(name, code) = @dynamic&.include?(name) ? (to_value(code) || code) : code

      # The value a method or helper ends on, when its branches differ.
      def retype_returns!(node, a, b)
        unsupported!(node, "an if whose branches return different types") unless @returns.nil? && @mode == :value
        refine_returns!(a, Code["", b], node) if [a, b].include?(T::NIL) || [a, b].any?(&:nilable?)
        unsupported!(node, "an if whose branches return different types") unless scalar?(a) && scalar?(b)

        fallback!(node, "the value, #{describe(a)} or #{describe(b)},")
        raise Retype
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
        if [left, right].any? { _1.type == T::NIL }
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

        fallback!(node, "the if's value, #{describe(a.type)} or #{describe(b.type)},")
        [T::VALUE, *values.map(&:rust)]
      end
    end
  end
end
