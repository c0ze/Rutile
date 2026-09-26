module Rutile
  module Build
    # Turns one Ruby body (a method, block or lambda) into Rust statements.
    # Every expression becomes a `Code` with a static type. Anything that
    # touches the `Ctx` is bound to a local before a call that borrows it
    # mutably, in Ruby's left-to-right order, and nothing is evaluated twice.
    class Translator
      # Rust's keywords, which a Ruby local may happen to be named.
      KEYWORDS = %w[as async await abstract become box break const continue crate do dyn else enum extern false final fn
                    for gen if impl in let loop macro match mod move mut override priv pub ref return static struct super
                    trait true try type typeof unsafe unsized use virtual where while yield].freeze
      # Keywords that can't be raw identifiers either.
      UNRAW = %w[crate self super Self].freeze
      SENDS = %w[send public_send __send__].freeze

      include ModelCalls
      include RecordMethods
      include Arguments
      include RecordCalls
      include Borrowing
      include WebCalls
      include ControlFlow
      include Blocks
      include Iteration
      include Lists
      include Calculations
      include Transactions
      include Expressions
      include Constants
      include Queries

      # env: :model (a callback; `self` is a record), :scope (`self` is a
      # relation), :controller (an action or helper), :constraint (a route
      # lambda). `result` is false for functions that don't return Result.
      # `returns` is the type a signature declares for the value the body ends on.
      def initialize(app, path, uses, env:, model: nil, self_var: nil, controller: nil, result: true, block: false, returns: nil)
        @returns = returns
        @app = app
        @path = path
        @uses = uses
        @env = env
        @model = model
        @self_var = self_var
        @controller = controller
        @result = result
        # A Ruby block's `return` leaves the enclosing method; Rust's wouldn't.
        @block = block
        @depth = 0
        @locals = {}
        @writes = Hash.new(0)
        @taken = Set.new(["ctx", "req", "self", self_var, *KEYWORDS].compact)
        @renames = {}
        @params = Set.new
        @lines = []
      end

      # A parameter the body can read, spelled `rust` in Rust.
      def declare(name, rust, type)
        @locals[name] = Code[rust, type, local: true]
        @params << name
        @taken << rust
      end

      # Translates a StatementsNode (or nil). `tail` says what the last
      # statement is: :unit (dropped), :value (returned) or :response (an
      # action's render or head). Returns the lines and the returned type.
      def body(node, tail)
        unsupported!(node, "rescue or ensure around a whole body") if node && !node.is_a?(Prism::StatementsNode)
        @mode = tail
        reserve(node) if node
        block(node ? node.body : [], tail)
      end

      private

      def block(statements, tail)
        saved = @lines
        locals = @locals.dup
        @lines = []
        return [["Ok(None)"], T::UNIT] if statements.empty? && tail == :filter
        raise Unsupported, "#{@path}: a body or branch that returns nothing" if statements.empty? && tail != :unit

        @depth += 1
        type = T::UNIT
        statements.each_with_index do |node, i|
          last = i == statements.size - 1
          unsupported!(statements[i + 1], "code after return") if node.is_a?(Prism::ReturnNode) && !last
          unsupported!(statements[i + 1], "code after raise") if rollback?(node) && !last
          # A method's trailing `return` is where it ends anyway.
          next if node.is_a?(Prism::ReturnNode) && last && @depth == 1 && tail == :unit && !@block && !node.arguments

          last && tail != :unit ? type = tail_statement(node, tail) : statement(node)
        end
        [@lines, type]
      ensure
        @depth -= 1
        @lines = saved
        # A local first assigned in here doesn't exist after it in Rust.
        @locals = locals
      end

      # Ruby's locals and parameters, so temporaries never take their names,
      # and how often each local is assigned, for `let mut`.
      def reserve(node)
        case node
        when Prism::LocalVariableWriteNode, Prism::LocalVariableOperatorWriteNode
          name = node.name.to_s
          @writes[name] += 1
          # One that would shadow the record, the Ctx or a keyword gets another name.
          reserved = ["ctx", "req", "self", @self_var, *KEYWORDS].include?(name)
          reserved ? (@renames[name] ||= fresh(name)) : @taken << name
        when Prism::RequiredParameterNode, Prism::LocalVariableTargetNode
          @taken << node.name.to_s
        end
        node.compact_child_nodes.each { reserve(_1) }
      end

      def tail_statement(node, tail)
        return filter_tail(node) if tail == :filter
        return branch(node, tail) if node.is_a?(Prism::IfNode) && node.subsequent

        code = @returns && tail == :value ? returned(value(node), node) : expr(node)
        if tail == :response
          raise Unsupported.at(@path, node, "an action that doesn't end in render or head") unless code.type == T::RESPONSE

          @lines << "Ok(#{code.rust})"
        else
          @lines << (@result ? "Ok(#{owned(code, code.type)})" : owned(code, code.type))
        end
        code.type
      end

      def statement(node)
        case node
        when Prism::IfNode, Prism::UnlessNode then conditional(node)
        when Prism::LocalVariableWriteNode then assign_local(node)
        when Prism::LocalVariableOperatorWriteNode then operator_assign(node)
        when Prism::InstanceVariableWriteNode then assign_ivar(node)
        when Prism::CallOrWriteNode then or_assign(node)
        when Prism::ReturnNode then early_return(node)
        else
          return if block_statement(node)

          code = expr(node)
          unsupported!(node, "render or head anywhere but at the end of an action or filter") if code.type == T::RESPONSE
          # A plain name (the record `create!` returns) as a statement does nothing.
          @lines << "#{code.rust};" unless code.rust.match?(/\A[a-z_][a-z0-9_]*\z/)
        end
      end

      def assign_local(node)
        name = node.name.to_s
        unsupported!(node, "assigning to the parameter #{name}") if @params.include?(name)
        rust = @renames.fetch(name, name)
        code = value(node.value)
        unsupported!(node, "a local assigned nil") if code.type == T::NIL
        if (known = @locals[name])
          raise Unsupported.at(@path, node, "giving #{name} a new type") unless known.type == code.type

          @lines << "#{rust} = #{owned(code, known.type)};"
        else
          # A local assigned again holds a String, whatever literal it starts from.
          again = @writes[name] > 1
          @lines << "let #{"mut " if again}#{rust} = #{owned(code, again ? code.type : nil)};"
          @locals[name] = Code[rust, code.type, local: true, literal: again ? nil : code.extra[:literal]]
        end
      end

      # `@post = ...` sets the controller's field.
      def assign_ivar(node)
        raise Unsupported.at(@path, node, "instance variables here") unless @env == :controller

        code = settle([value(node.value)], :none).first
        unsupported!(node, "assigning nil to #{node.name}") if code.type == T::NIL
        name = node.name.to_s.delete_prefix("@")
        @controller.ivar(name, code.type, node)
        @lines << "self.#{name} = #{code.type.nilable? ? owned(code) : "Some(#{owned(code)})"};"
      end

      # `self.published_at ||= Time.current` assigns only when nil (or false).
      def or_assign(node)
        unless @env == :model && node.receiver.is_a?(Prism::SelfNode)
          raise Unsupported.at(@path, node, "||= on anything but an attribute of self")
        end

        attribute = node.read_name.to_s
        type = @app.column_type(@model, attribute) or raise Unsupported.at(@path, node, "||= on #{attribute}")
        field = "ctx[#{@self_var}].#{attribute}"
        saved = @lines
        @lines = []
        value = settle([expr(node.value)], :write).first
        unless value.type == type
          what = value.type.nilable? ? "a value that may be nil" : "#{describe(value.type)} on #{attribute}"
          unsupported!(node, "||= with #{what}")
        end
        assignment = [*@lines, "#{field} = #{assigned(@model, attribute, type, value)};"]
        @lines = saved
        falsy = type == T::BOOL ? "!#{field}.unwrap_or(false)" : "#{field}.is_none()"
        @lines.push("if #{falsy} {", *assignment, "}")
      end

      def expr(node)
        case node
        when Prism::StringNode then Code[Names.str(node.unescaped), T::STR, literal: true]
        when Prism::InterpolatedStringNode then interpolation(node)
        when Prism::SymbolNode then Code[Names.str(node.unescaped), T::STR, literal: true]
        when Prism::IntegerNode then Code[node.value.to_s, T::INT]
        when Prism::FloatNode then float_literal(node)
        when Prism::NilNode then Code["None", T::NIL]
        when Prism::AndNode, Prism::OrNode then logic(node)
        when Prism::IfNode then ternary(node)
        when Prism::TrueNode then Code["true", T::BOOL]
        when Prism::FalseNode then Code["false", T::BOOL]
        when Prism::ParenthesesNode then expr(only(node.body&.body || [], node))
        when Prism::LocalVariableReadNode then @locals[node.name.to_s] || unsupported!(node, "#{node.name} before it's assigned")
        when Prism::ItLocalVariableReadNode then @locals["it"] || unsupported!(node, "it outside a block")
        when Prism::InstanceVariableReadNode then ivar(node)
        when Prism::SelfNode then self_code(node)
        when Prism::ConstantReadNode then constant(node)
        when Prism::HashNode then json_literal(node)
        when Prism::CallNode then call(node)
        else unsupported!(node, node.type.to_s.delete_suffix("_node").tr("_", " "))
        end
      end

      def ivar(node) = ivar_named(node.name.to_s.delete_prefix("@"), node)

      # `@current_user`, or `current_user` through an attr_reader.
      def ivar_named(name, node)
        unsupported!(node, "instance variables here") unless @env == :controller
        type = @controller.ivar_type(name) or unsupported!(node, "reading @#{name} before a filter assigns it")
        # A String field is cloned: the controller is borrowed, not owned.
        field = T.nilable(type).copy? ? "self.#{name}" : "self.#{name}.clone()"
        Code[field, T.nilable(type), hint: name]
      end

      def self_code(node)
        case @env
        when :model then Code[@self_var, T.record(@model)]
        when :scope then Code["self", T.relation(@model)]
        else unsupported!(node, "self here")
        end
      end

      def call(node)
        args = node.arguments&.arguments || []
        name = node.name.to_s
        return block_call(node, name, args) if node.block
        unsupported!(node, "raise where a value belongs") if name == "raise" && node.receiver.nil?
        # design.md: `send(:title)` is a direct call to `title`.
        if SENDS.include?(name) && (args.first.is_a?(Prism::SymbolNode) || args.first.is_a?(Prism::StringNode))
          name = args.first.unescaped
          args = args.drop(1)
        end
        return self_call(node, name, args) if node.receiver.nil?
        return extremum(node, name) if node.receiver.is_a?(Prism::ArrayNode) && %w[max min].include?(name) && args.empty?
        operator = name == "!" || (Expressions::COMPARE + Expressions::ARITHMETIC).include?(name)
        unsupported!(node, "&. with an operator") if operator && node.safe_navigation?
        return negate(expr(node.receiver), node) if name == "!" && args.empty?
        return compare(node, name, args.first) if Expressions::COMPARE.include?(name) && args.size == 1
        return arithmetic(node, name, args.first) if Expressions::ARITHMETIC.include?(name) && args.size == 1

        receiver = expr(node.receiver)
        unsupported!(node, "a call chained after &.") if receiver.extra[:nav]
        # Ruby evaluates the receiver before the arguments, which matters
        # only when an argument can do something.
        receiver = bind(receiver) if impure?(receiver) && !args.all? { literal?(_1) }
        return safe_call(receiver, node, name, args) if node.safe_navigation?

        send_to(receiver, node, name, args)
      end

      def self_call(node, name, args)
        case @env
        when :model then send_to(Code[@self_var, T.record(@model)], node, name, args)
        when :scope then send_to(Code["self", T.relation(@model)], node, name, args)
        when :controller then controller_call(node, name, args) || unsupported!(node, "#{name} in a controller")
        else unsupported!(node, name)
        end
      end

      def send_to(receiver, node, name, args)
        handler = "on_#{receiver.type.kind}"
        found = respond_to?(handler, true) ? send(handler, receiver, node, name, args) : nil
        found || unsupported!(node, "#{name} on #{describe(receiver.type)}")
      end
    end
  end
end
