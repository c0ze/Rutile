module Rutile
  module Build
    # Calls on records, possibly-nil values, relations, model classes, Time,
    # strings and a record's errors. Each returns a Code, or nil for a
    # method it doesn't know (which the translator reports).
    module ModelCalls
      private

      def on_record(receiver, node, name, args)
        model = receiver.type.model
        if args.empty? && (type = @app.column_type(model, name))
          receiver = settle([receiver], :read).first
          return Code["#{ctx_recv}[#{receiver.rust}].#{name}#{".clone()" unless type.copy?}", T.nilable(type), :read, hint: name]
        end
        if name.end_with?("=") && args.size == 1 && (type = @app.column_type(model, name.chomp("=")))
          return write_attribute(receiver, name.chomp("="), type, args.first, node)
        end
        if args.empty? && @app.enum_predicate(model, name)
          receiver = settle([receiver], :read).first
          return Code["#{ctx_recv}[#{receiver.rust}].#{Names.method(name)}()", T::BOOL, :read]
        end
        assoc = @app.association(model, name)
        return association(receiver, model, assoc) if assoc && args.empty?

        record_method(receiver, node, model, name, args)
      end

      def write_attribute(receiver, attribute, type, arg, node)
        value = expr(arg)
        unless [type, T.nilable(type), T::NIL].include?(value.type)
          unsupported!(node, "assigning #{describe(value.type)} to #{attribute}")
        end
        receiver, value = settle([receiver, value], :write)
        assigned = value.type.nilable? || value.type == T::NIL ? owned(value) : "Some(#{owned(value, type)})"
        Code["#{ctx_recv}[#{receiver.rust}].#{attribute} = #{assigned}", T::UNIT, :write]
      end

      def association(receiver, model, assoc)
        const = "#{model}::#{Names.constant(assoc["name"])}"
        target = assoc["class_name"]
        use_model(target)
        if assoc["macro"] == "belongs_to"
          receiver = settle([receiver], :write).first
          return Code["#{const}.get(#{ctx_mut}, #{receiver.rust})?", T.nilable(T.record(target)), :write, hint: assoc["name"]]
        end
        # The owner is named once: `build` uses it again.
        receiver = local!(receiver) if impure?(receiver) || receiver.reads?
        Code["#{const}.of(#{ctx_ref}, #{receiver.rust})", T.relation(target), :read, hint: assoc["name"],
             via: [receiver.rust, model, assoc["name"]]]
      end

      def record_method(receiver, node, model, name, args)
        need_ctx!(node)
        case [name, args.size]
        when ["save", 0] then mutate(receiver, "save", T::BOOL)
        when ["save!", 0] then mutate(receiver, "save_bang", T::UNIT)
        when ["destroy", 0] then mutate(receiver, "destroy", T::BOOL)
        when ["destroy!", 0] then mutate(receiver, "destroy_bang", T::UNIT)
        when ["valid?", 0] then mutate(receiver, "is_valid", T::BOOL)
        when ["reload", 0] then mutate(receiver, "reload", T::UNIT)
        when ["increment!", 1] then mutate(receiver, "increment_bang", T::UNIT, Names.str(symbol!(args.first, node)), "1")
        when ["update", 1] then update(receiver, node, args.first)
        when ["errors", 0]
          receiver = settle([receiver], :read).first
          Code["#{ctx_recv}.errors(#{receiver.rust})", T.errors(model), :read, owner: receiver.rust]
        when ["as_json", 0], ["as_json", 1] then render_record(receiver, model, args.first, node)
        end
      end

      def mutate(receiver, method, type, *rest)
        receiver = settle([receiver], :write).first
        Code["#{ctx_recv}.#{method}(#{[receiver.rust, *rest].join(", ")})?", type, :write]
      end

      # `record.update(attributes)`: assign, then save, naming each once.
      def update(receiver, node, arg)
        attributes = expr(arg)
        unsupported!(node, "update with #{describe(attributes.type)}") unless attributes.type == T::ATTRIBUTES
        receiver = local!(receiver)
        attributes = local!(attributes)
        @lines << "#{ctx_recv}.assign(#{receiver.rust}, &#{attributes.rust})?;"
        Code["#{ctx_recv}.save(#{receiver.rust})?", T::BOOL, :write]
      end

      # Ruby raises NoMethodError on nil; the methods nil itself answers
      # stay on the Option.
      def on_nilable(receiver, node, name, args)
        inner = receiver.type.inner
        case name
        when "nil?" then return Code["#{receiver.rust}.is_none()", T::BOOL, receiver.ctx]
        when "to_s" then return inner == T::STR ? Code["#{receiver.rust}.unwrap_or_default()", T::STR, receiver.ctx, hint: receiver.hint] : nil
        when "present?", "blank?"
          if inner == T::STR
            @uses.rt("Blank")
            return Code["#{receiver.rust}.#{Names.method(name)}()", T::BOOL, receiver.ctx]
          end
          # Only true is present; nil and false are blank.
          return Code["#{receiver.rust} #{name == "present?" ? "==" : "!="} Some(true)", T::BOOL, receiver.ctx] if inner == T::BOOL

          return Code["#{receiver.rust}.#{name == "present?" ? "is_some" : "is_none"}()", T::BOOL, receiver.ctx]
        end
        @uses.rt("Error")
        unwrapped = Code["#{receiver.rust}.ok_or(Error::Nil { what: #{Names.str(name)} })?", inner, receiver.ctx,
                         hint: receiver.hint, **receiver.extra.except(:local, :literal, :safe)]
        send_to(unwrapped, node, name, args)
      end

      def on_relation(receiver, node, name, args)
        model = receiver.type.model
        chain = ->(rust) { Code["#{receiver.rust}#{rust}", T.relation(model), receiver.ctx, hint: receiver.hint] }
        case name
        when "where" then chain.(pairs(args, node).map { |column, value| where(model, column, value, node) }.join)
        when "order" then chain.(order(args, node))
        when "limit" then chain.(".limit(#{only(args, node).then { |n| n.is_a?(Prism::IntegerNode) ? n.value : unsupported!(n, "a non-literal limit") }})")
        when "includes" then chain.(args.map { ".includes(&#{model}::#{Names.constant(symbol!(_1, node))})" }.join)
        when "all" then receiver
        when "new", "build" then build_through(receiver, node, args)
        when "as_json" then render_relation(receiver, model, args.first, node)
        else scope_call(receiver, model, name, node, args)
        end
      end

      def where(model, column, value, node)
        if value.is_a?(Prism::RangeNode)
          unsupported!(node, "a where range other than `x..`") unless value.left && value.right.nil? && !value.exclude_end?
          bound = expr(value.left)
          unsupported!(node, "a where range from a value that may be nil") if bound.type.nilable?
          return ".where_gte(#{Names.str(column)}, #{owned(bound)})"
        end
        unsupported!(node, "where on #{column}, which #{model} doesn't have") unless @app.column_type(model, column)
        code = expr(value)
        if code.type == T::NIL
          @uses.rt("Value")
          return ".where_eq(#{Names.str(column)}, Value::Nil)"
        end
        unsupported!(node, "where with #{describe(code.type)}") if code.type.nilable? || code.reads?
        ".where_eq(#{Names.str(column)}, #{owned(code)})"
      end

      def order(args, node)
        args.flat_map do |arg|
          next [".order_asc(#{Names.str(symbol!(arg, node))})"] if arg.is_a?(Prism::SymbolNode)

          pairs([arg], node).map do |column, direction|
            dir = symbol!(direction, node)
            unsupported!(node, "order direction :#{dir}") unless %w[asc desc].include?(dir)
            ".order_#{dir}(#{Names.str(column)})"
          end
        end.join
      end

      def scope_call(receiver, model, name, node, args)
        scope = @app.scope(model, name) or return nil
        path = scope.dig("source", "path")
        trait = path == Scopes::APPLICATION_RECORD ? "ApplicationRecordScopes" : "#{model}Scopes"
        use_model(trait) unless trait == "#{@model}Scopes" && %i[model scope].include?(@env)
        values = args.map { owned(expr(_1)) }
        Code["#{receiver.rust}.#{name}(#{values.join(", ")})", T.relation(model), receiver.ctx, hint: receiver.hint]
      end

      # `@post.comments.new(attributes)`: a child pointing at its owner.
      def build_through(receiver, node, args)
        owner, owner_model, assoc = receiver.extra[:via] || (return nil)
        target = receiver.type.model
        attributes = settle([attributes_arg(args, node)], :write).first
        @uses.rt("Model")
        Code["#{owner_model}::#{Names.constant(assoc)}.build(#{ctx_mut}, #{owner}, " \
             "#{target}::from_attributes(&#{attributes.rust})?)?", T.record(target), :write, hint: Names.snake(target)]
      end

      def attributes_arg(args, node)
        code = expr(only(args, node))
        code.type == T::ATTRIBUTES ? code : unsupported!(node, "new with #{describe(code.type)}")
      end

      def on_class(receiver, node, name, args)
        model = receiver.type.model
        hint = Names.snake(model)
        @uses.rt("Model")
        case name
        when "new"
          need_ctx!(node)
          attributes = settle([attributes_arg(args, node)], :write).first
          Code["#{ctx_recv}.build(#{model}::from_attributes(&#{attributes.rust})?)", T.record(model), :write, hint:]
        when "find"
          need_ctx!(node)
          id = settle([expr(only(args, node))], :write).first
          Code["#{model}::find(#{ctx_mut}, #{owned(id)})?", T.record(model), :write, hint:]
        when "find_by", "find_by!"
          need_ctx!(node)
          column, value = only(pairs(args, node), node)
          value = settle([expr(value)], :write).first
          type = name == "find_by" ? T.nilable(T.record(model)) : T.record(model)
          Code["#{model}::#{Names.method(name)}(#{ctx_mut}, #{Names.str(column)}, #{owned(value)})?", type, :write, hint:]
        else
          table = @app.model(model)["table_name"]
          on_relation(Code["#{model}::all()", T.relation(model), hint: table], node, name, args)
        end
      end

      def on_time_class(_receiver, _node, name, args)
        return nil unless %w[current now].include?(name) && args.empty?

        @uses.rt("now")
        Code["now()", T::TIME]
      end

      def on_str(receiver, _node, name, args)
        return nil unless args.empty?

        case name
        when "strip", "downcase", "upcase"
          @uses.rt("RubyString")
          Code["#{receiver.rust}.#{name}()", T::STR, receiver.ctx, hint: receiver.hint]
        when "to_s" then receiver
        when "present?", "blank?"
          @uses.rt("Blank")
          Code["#{receiver.rust}.#{Names.method(name)}()", T::BOOL, receiver.ctx]
        end
      end

      # `errors.add(:attribute, "message")` on the record being validated.
      def on_errors(receiver, node, name, args)
        owner = receiver.extra[:owner]
        return nil unless name == "add" && args.size == 2 && owner

        message = settle([expr(args[1])], :write).first
        unsupported!(node, "an error message that isn't a string") unless message.type == T::STR
        Code["#{ctx_recv}.errors_mut(#{owner}).add(#{Names.str(symbol!(args[0], node))}, #{owned(message)})", T::UNIT, :write]
      end
    end
  end
end
