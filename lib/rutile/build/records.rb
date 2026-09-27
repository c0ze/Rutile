module Rutile
  module Build
    # Creating and updating records with attributes: params-derived
    # `Attributes`, or a literal hash whose keys are columns and belongs_to
    # associations.
    module RecordCalls
      # RustOnRails keeps the changes to save, not those of the last save.
      LAST_SAVE = "which needs the last save's changes,"

      private

      # `will_save_change_to_status?`; nil for any other dirty method.
      def change_to_save(receiver, model, name, node)
        if (column = @app.change_to_save(model, name))
          receiver = settle([receiver], :read).first
          return Code["#{ctx_recv}.attribute_changed(#{receiver.rust}, #{Names.str(column)})", T::BOOL, :read]
        end
        unsupported!(node, "#{name}, #{LAST_SAVE}") if @app.saved_change?(name)
      end

      def hash?(node) = node.is_a?(Prism::KeywordHashNode) || node.is_a?(Prism::HashNode)

      # `Model.create!(attributes)`, `(key: value)`, and the same through a
      # has_many (`via` is the owner, the owner's model and the association).
      # Ruby returns the record whether or not `create` saved it.
      def create_record(model, arg, bang, node, via: nil)
        @uses.rt("Model")
        use_model(model)
        use_model(via[1]) if via
        blank = hash?(arg)
        record = if blank
                   @uses.rt("Record")
                   "#{model}::new_record()"
                 else
                   attributes = settle([attributes_arg([arg], node)], :write).first
                   "#{model}::from_attributes(&#{attributes.rust})?"
                 end
        built = if via
                  owner, owner_model, assoc = via
                  "#{owner_model}::#{Names.constant(assoc)}.build(#{ctx_mut}, #{owner}, #{record})?"
                else
                  "#{ctx_recv}.build(#{record})"
                end
        handle = bind(Code[built, T.record(model), :write, hint: Names.snake(model)])
        if blank
          assign_pairs(handle, model, pairs([arg], node), node)
          # Rails fills tokens after `new` assigns, so a token the hash blanked gets one.
          @lines << "#{ctx_recv}.fill_secure_tokens(#{handle.rust})?;" if ModelMacros.initialize_tokens?(@app, model)
        end
        @lines << "#{ctx_recv}.#{bang ? "save_bang" : "save"}(#{handle.rust})?;"
        handle
      end

      # Each key a column (enum columns take labels) or a belongs_to. Ruby
      # evaluates the whole hash before anything is assigned, so every value
      # that reads the Ctx is a local first.
      def assign_pairs(handle, model, entries, node)
        values = in_order(entries.map(&:last)) { value(_1) }.map { _1.reads? ? bind(_1) : _1 }
        entries.zip(values).each do |(key, _), value|
          if (type = @app.column_type(model, key))
            @lines << "#{write_value(handle, key, type, value, node).rust};"
          elsif (assoc = @app.association(model, key)) && assoc["macro"] == "belongs_to"
            set_association(handle, model, assoc, value, node)
          else
            unsupported!(node, "#{key}, which #{model} has no column or belongs_to for,")
          end
        end
      end

      # Assigning nil (or a record that isn't there) clears the key, as in Rails.
      def set_association(handle, model, assoc, value, node)
        target = assoc["class_name"]
        clear = "#{ctx_recv}[#{handle.rust}].#{assoc["foreign_key"]} = None;"
        return @lines << clear if value.type == T::NIL
        unless [T.record(target), T.nilable(T.record(target))].include?(value.type)
          unsupported!(node, "#{assoc["name"]}: #{describe(value.type)}")
        end

        use_model(model)
        set = ->(v) { "#{model}::#{Names.constant(assoc["name"])}.set(#{ctx_mut}, #{handle.rust}, #{v})?;" }
        if value.type.nilable?
          var = local!(value).rust
          @lines.push("if let Some(#{var}) = #{var} {", set.(var), "} else {", clear, "}")
        else
          @lines << set.(value.rust)
        end
      end

      # `record.update!(attributes)` or `(key: value)`: assign, then save or raise.
      def update_record(receiver, node, arg, bang)
        receiver = local!(receiver)
        if hash?(arg)
          assign_pairs(receiver, receiver.type.model, pairs([arg], node), node)
        else
          attributes = expr(arg)
          unsupported!(node, "update with #{describe(attributes.type)}") unless attributes.type == T::ATTRIBUTES
          attributes = local!(attributes)
          @lines << "#{ctx_recv}.assign(#{receiver.rust}, &#{attributes.rust})?;"
        end
        bang ? Code["#{ctx_recv}.save_bang(#{receiver.rust})?", T::UNIT, :write] : Code["#{ctx_recv}.save(#{receiver.rust})?", T::BOOL, :write]
      end

      # `relation.find(id)`. The relation is an owned value, so it can be
      # built before the Ctx is borrowed mutably.
      def find_in(receiver, model, args, node)
        need_ctx!(node)
        id = settle([value(only(args, node))], :write).first
        Code["#{receiver.rust}.find(#{ctx_mut}, #{owned(id)})?", T.record(model), :write, hint: Names.snake(model)]
      end

      # `relation.include?(record)`: an exists? query, as on an unloaded
      # relation in Rails; nil is false.
      def include_in(receiver, model, args, node)
        need_ctx!(node)
        record = settle([value(only(args, node))], :write).first
        unless [T.record(model), T.nilable(T.record(model))].include?(record.type)
          unsupported!(node, "include? with #{describe(record.type)}")
        end
        Code["#{receiver.rust}.contains(#{ctx_mut}, #{record.rust})?", T::BOOL, :write]
      end

      # `where.not(status: :done)`
      def on_where_chain(receiver, node, name, args)
        return nil unless name == "not"

        model = receiver.type.model
        entries = pairs(args, node)
        # Rails negates the conjunction: NOT(a AND b), not NOT a AND NOT b.
        unsupported!(node, "where.not with more than one condition") if entries.size > 1
        # The value is read after the relation, as Ruby reads it; nil (or
        # a value that turns out nil) is IS NOT NULL.
        receiver, conditions = after(receiver) do
          entries.map do |column, operand|
            unsupported!(node, "where.not on #{column}, which #{model} doesn't have") unless @app.column_type(model, column)
            code = value(operand)
            bindable!(code, node, "where.not")
            [".where_not(#{Names.str(column)}, #{where_value(code)})", code]
          end
        end
        Code["#{receiver.rust}#{conditions.map(&:first).join}", T.relation(model), touch(receiver, *conditions.map(&:last)),
             hint: receiver.hint]
      end
    end
  end
end
