module Rutile
  module Build
    # Calls on records, possibly-nil values, relations, model classes, Time,
    # strings and a record's errors. Each returns a Code, or nil for a
    # method it doesn't know (which the translator reports).
    module ModelCalls
      private

      def on_record(receiver, node, name, args)
        model = receiver.type.model
        # The model's own method wins over what Rails would define.
        return model_method(receiver, node, model, name, args) if @app.model_methods.definition(model, name)
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
        query = @app.column_type(model, name.delete_suffix("?")) if name.end_with?("?") && args.empty?
        return query_attribute(receiver, name.delete_suffix("?"), query) if query

        assoc = @app.association(model, name)
        return association(receiver, model, assoc, node) if assoc && args.empty?

        record_method(receiver, node, model, name, args)
      end

      # `active?`: Rails' query_attribute. nil and false are false; a String
      # must not be blank, a number not zero.
      def query_attribute(receiver, attribute, type)
        receiver = settle([receiver], :read).first
        field = "#{ctx_recv}[#{receiver.rust}].#{attribute}"
        rust = case type.kind
               when :bool then "#{field} == Some(true)"
               when :str
                 @uses.rt("Blank")
                 "#{field}.as_deref().is_some_and(|value| !value.is_blank())"
               when :int then "#{field}.is_some_and(|value| value != 0)"
               when :float then "#{field}.is_some_and(|value| value != 0.0)"
               else "#{field}.is_some()"
               end
        Code[rust, T::BOOL, :read]
      end

      def write_attribute(receiver, attribute, type, arg, node) = write_value(receiver, attribute, type, expr(arg), node)

      def write_value(receiver, attribute, type, value, node)
        unless [type, T.nilable(type), T::NIL].include?(value.type)
          unsupported!(node, "assigning #{describe(value.type)} to #{attribute}")
        end
        receiver, value = settle([receiver, value], :write)
        Code["#{ctx_recv}[#{receiver.rust}].#{attribute} = #{assigned(receiver.type.model, attribute, type, value)}", T::UNIT, :write]
      end

      # A value for an attribute field, normalized as the attribute writer
      # would.
      def assigned(model, attribute, type, value)
        normalize = ModelMacros.normalizer(@app, model, attribute)
        use_model(model) if normalize
        return "None" if value.type == T::NIL
        return (normalize ? "#{owned(value)}.map(#{normalize})" : owned(value)) if value.type.nilable?

        normalize ? "Some(#{normalize}(#{owned(value, type)}))" : "Some(#{owned(value, type)})"
      end

      def association(receiver, model, assoc, node)
        # What the model file refuses to declare, callers can't use.
        extra = assoc["options"].keys - ModelFile::ASSOCIATION_OPTIONS
        unsupported!(node, "#{assoc["macro"]} :#{assoc["name"]} with #{extra.join(", ")}") unless extra.empty?
        unsupported!(node, "#{assoc["macro"]} :#{assoc["name"]}") unless %w[belongs_to has_many].include?(assoc["macro"])
        const = "#{model}::#{Names.constant(assoc["name"])}"
        target = assoc["class_name"]
        # The constant names the owner; the target is imported where it's named.
        use_model(model)
        if assoc["macro"] == "belongs_to"
          receiver = settle([receiver], :write).first
          return Code["#{const}.get(#{ctx_mut}, #{receiver.rust})?", T.nilable(T.record(target)), :write, hint: assoc["name"]]
        end
        # The owner is named once: `build` uses it again.
        receiver = local!(receiver) if impure?(receiver) || receiver.reads?
        if assoc["options"]["through"]
          link, = ModelFile.through_parts(@app, model, assoc)
          unsupported!(node, "has_many :#{assoc["name"]} through #{assoc["options"]["through"]} in this shape") unless link
          joined = { @app.model(link["class_name"])["table_name"] => link["class_name"] }
          return Code["#{const}.of(#{ctx_ref}, #{receiver.rust})", T.relation(target), :read, hint: assoc["name"],
                      through: assoc["name"], joined:]
        end
        Code["#{const}.of(#{ctx_ref}, #{receiver.rust})", T.relation(target), :read, hint: assoc["name"],
             via: [receiver.rust, model, assoc["name"]]]
      end

      # Ruby raises NoMethodError on nil; the methods nil itself answers
      # stay on the Option.
      def on_nilable(receiver, node, name, args)
        inner = receiver.type.inner
        case name
        when "nil?" then return Code["#{receiver.rust}.is_none()", T::BOOL, receiver.ctx]
        when "to_s" then return inner == T::STR ? Code["#{owned(receiver)}.unwrap_or_default()", T::STR, receiver.ctx, hint: receiver.hint] : nil
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
        if (through = receiver.extra[:through]) && %w[new build create create! includes].include?(name)
          unsupported!(node, "#{name} through has_many :#{through}")
        end
        chain = ->(rust) { relation(receiver, "#{receiver.rust}#{rust}") }
        case name
        when "where"
          return Code[receiver.rust, T.where_chain(model), receiver.ctx, hint: receiver.hint] if args.empty?

          args.first.is_a?(Prism::StringNode) ? where_sql(receiver, args, node) : where_pairs(receiver, model, args, node)
        when "order" then chain.(order(args, node))
        when "limit", "offset" then paginate(receiver, name, args, node)
        when "joins" then joins(receiver, model, args, node)
        when "includes" then chain.(args.map { include_one(model, symbol!(_1, node), node) }.join)
        when "all" then receiver
        when "new", "build" then build_through(receiver, node, args)
        when "create", "create!"
          via = receiver.extra[:via] or return nil
          create_record(model, only(args, node), name.end_with?("!"), node, via:)
        when "as_json" then render_relation(receiver, model, args.first, node)
        when "find" then find_in(receiver, model, args, node)
        when "include?" then include_in(receiver, model, args, node)
        when "sanitize_sql_like" then sanitize_like(args, node)
        when *Calculations::METHODS then calculation(receiver, model, name, args, node)
        else scope_call(receiver, model, name, node, args)
        end
      end

      def scope_call(receiver, model, name, node, args)
        scope = @app.scope(model, name) or return nil
        path = scope.dig("source", "path")
        trait = path == Scopes::APPLICATION_RECORD ? "ApplicationRecordScopes" : "#{model}Scopes"
        use_model(trait) unless trait == "#{@model}Scopes" && %i[model scope].include?(@env)
        receiver, values = after(receiver) { scope_arguments(model, scope, args, node) }
        relation(receiver, "#{receiver.rust}.#{name}(#{values.map(&:first).join(", ")})", *values.map(&:last))
      end

      # The arguments as the scope's parameters type them. A param value
      # goes where a String is wanted only as a String (`to_str`): the String
      # methods the scope calls would raise on anything else.
      def scope_arguments(model, scope, args, node)
        if scope["origin"] == "framework"
          unsupported!(node, "arguments to scope :#{scope["name"]}") unless args.empty?
          return []
        end
        path, line = scope["source"].values_at("path", "line")
        names, types, strings = begin
          ScopeParameters.of(@app, model, @app.source.block_at(path, line), path)
        rescue Unsupported
          raise Skipped, scope["name"] # the model file reports why
        end
        unsupported!(node, "scope :#{scope["name"]} with #{args.size} arguments for #{names.size}") unless args.size == names.size
        codes = settle(in_order(args) { value(_1) }, :none)
        names.zip(codes).map do |param, code|
          want = types[param]
          next [owned(code, want), code] if code.type == want
          next ["#{code.rust}.to_str()?", code] if code.type == T::VALUE && strings.include?(param)

          unsupported!(node, "passing #{describe(code.type)} to scope :#{scope["name"]}'s #{param} (#{describe(want)})")
        end
      end

      # `@post.comments.new(attributes)`: a child pointing at its owner.
      def build_through(receiver, node, args)
        owner, owner_model, assoc = receiver.extra[:via] || (return nil)
        target = receiver.type.model
        attributes = settle([attributes_arg(args, node)], :write).first
        @uses.rt("Model")
        use_model(owner_model)
        use_model(target)
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
          id = settle([value(only(args, node))], :write).first
          Code["#{model}::find(#{ctx_mut}, #{owned(id)})?", T.record(model), :write, hint:]
        when "create", "create!"
          need_ctx!(node)
          create_record(model, only(args, node), name.end_with?("!"), node)
        when "find_by", "find_by!"
          need_ctx!(node)
          column, operand = only(pairs(args, node), node)
          key = settle([value(operand)], :write).first
          type = name == "find_by" ? T.nilable(T.record(model)) : T.record(model)
          Code["#{model}::#{Names.method(name)}(#{ctx_mut}, #{Names.str(column)}, #{owned(key)})?", type, :write, hint:]
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

      # `Date.current` is today in the app's zone, which the runtime takes to
      # be UTC; `Date.today` is the machine's local date.
      def on_date_class(_receiver, node, name, args)
        return nil unless %w[current today].include?(name) && args.empty?

        zone = @app.manifest.dig("config", "time_zone")
        unsupported!(node, "Date.current with config.time_zone #{zone}") if name == "current" && zone != "UTC"
        function = name == "current" ? "today" : "local_today"
        @uses.rt(function)
        Code["#{function}()", T::DATE]
      end

      def on_str(receiver, node, name, args)
        return nil unless args.empty?
        # A Symbol's `to_s` is a String; its `downcase` is another Symbol.
        return Code[receiver.rust, T::STR, receiver.ctx, **receiver.extra.except(:symbol)] if name == "to_s"
        unsupported!(node, "#{name} on a Symbol") if receiver.extra[:symbol]

        case name
        when "strip", "downcase", "upcase"
          @uses.rt("RubyString")
          Code["#{receiver.rust}.#{name}()", T::STR, receiver.ctx, hint: receiver.hint]
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
