module Rutile
  module Build
    # Creating and updating records with attributes: params-derived
    # `Attributes`, or a literal hash whose keys are columns and belongs_to
    # associations.
    module RecordCalls
      private

      def hash?(node) = node.is_a?(Prism::KeywordHashNode) || node.is_a?(Prism::HashNode)

      # `Model.create!(attributes)`, `(key: value)`, and the same through a
      # has_many (`via` is the owner, the owner's model and the association).
      # Ruby returns the record whether or not `create` saved it.
      def create_record(model, arg, bang, node, via: nil)
        @uses.rt("Model")
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
        assign_pairs(handle, model, pairs([arg], node), node) if blank
        @lines << "#{ctx_recv}.#{bang ? "save_bang" : "save"}(#{handle.rust})?;"
        handle
      end

      # Each key a column (enum columns take labels) or a belongs_to.
      def assign_pairs(handle, model, entries, node)
        entries.each do |key, value|
          if (type = @app.column_type(model, key))
            @lines << "#{write_attribute(handle, key, type, value, node).rust};"
          elsif (assoc = @app.association(model, key)) && assoc["macro"] == "belongs_to"
            set_association(handle, model, assoc, value, node)
          else
            unsupported!(node, "#{key}, which #{model} has no column or belongs_to for,")
          end
        end
      end

      # A nil target leaves the key unset, and belongs_to's check reports it.
      def set_association(handle, model, assoc, value_node, node)
        value = settle([expr(value_node)], :write).first
        target = assoc["class_name"]
        unless [T.record(target), T.nilable(T.record(target))].include?(value.type)
          unsupported!(node, "#{assoc["name"]}: #{describe(value.type)}")
        end
        set = ->(v) { "#{model}::#{Names.constant(assoc["name"])}.set(#{ctx_mut}, #{handle.rust}, #{v})?;" }
        if value.type.nilable?
          var = local!(value).rust
          @lines.push("if let Some(#{var}) = #{var} {", set.(var), "}")
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

      # `where.not(status: :done)`
      def on_where_chain(receiver, node, name, args)
        return nil unless name == "not"

        model = receiver.type.model
        conditions = pairs(args, node).map do |column, value|
          unsupported!(node, "where.not on #{column}, which #{model} doesn't have") unless @app.column_type(model, column)
          code = expr(value)
          if code.type == T::NIL
            @uses.rt("Value")
            next ".where_not(#{Names.str(column)}, Value::Nil)"
          end

          unsupported!(node, "where.not with #{describe(code.type)}") if code.type.nilable? || code.reads?
          ".where_not(#{Names.str(column)}, #{owned(code)})"
        end
        Code["#{receiver.rust}#{conditions.join}", T.relation(model), receiver.ctx, hint: receiver.hint]
      end
    end
  end
end
