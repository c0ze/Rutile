module Rutile
  module Build
    # Instance methods on a record: persistence, Rails' enum bang methods,
    # and the model's own methods. Each returns a Code, or nil for a method
    # it doesn't know.
    module RecordMethods
      private

      # `@project.archive!`, `task.overdue?`: `Model::method(ctx, record)`.
      # Ruby lets only the record itself call a private one.
      def model_method(receiver, node, model, name, args)
        own = @env == :model && model == @model && receiver.rust == @self_var
        if @app.model_methods.private?(model, name) && !own
          unsupported!(node, "the private method #{name} from outside #{model}")
        end
        need_ctx!(node)
        type = @app.model_methods.type(model, name, [@path, node])
        signature = @app.model_methods.signature(model, name)
        receiver, values = after(receiver) { call_arguments(signature, args, node, name, bind: :ctx) }
        receiver = settle([receiver], :write).first
        use_model(model)
        call = [ctx_mut, receiver.rust, *values].join(", ")
        Code["#{model}::#{Names.method(name)}(#{call})?", type, :write, hint: name.delete_suffix("?").delete_suffix("!")]
      end

      # `task.done!`, the enum's bang method, is `update!(status: :done)`.
      def enum_bang(receiver, node, attribute, label)
        receiver = local!(receiver)
        write = write_value(receiver, attribute, T::STR, Code[Names.str(label), T::STR, literal: true], node)
        @lines << "#{write.rust};"
        Code["#{ctx_recv}.save_bang(#{receiver.rust})?", T::UNIT, :write]
      end

      def record_method(receiver, node, model, name, args)
        need_ctx!(node)
        dirty = change_to_save(receiver, model, name, node) if args.empty?
        return dirty if dirty

        bang = @app.enum_bang(model, name) if args.empty?
        return enum_bang(receiver, node, *bang) if bang

        case [name, args.size]
        when ["save", 0] then mutate(receiver, "save", T::BOOL)
        when ["save!", 0] then mutate(receiver, "save_bang", T::UNIT)
        when ["destroy", 0] then mutate(receiver, "destroy", T::BOOL)
        when ["destroy!", 0] then mutate(receiver, "destroy_bang", T::UNIT)
        when ["valid?", 0] then mutate(receiver, "is_valid", T::BOOL)
        when ["reload", 0] then mutate(receiver, "reload", T::UNIT)
        when ["increment!", 1] then mutate(receiver, "increment_bang", T::UNIT, Names.str(symbol!(args.first, node)), "1")
        when ["update", 1] then hash?(args.first) ? update_record(receiver, node, args.first, false) : update(receiver, node, args.first)
        when ["update!", 1] then update_record(receiver, node, args.first, true)
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
    end
  end
end
