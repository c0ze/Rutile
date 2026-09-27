module Rutile
  module Build
    # `RestockJob.perform_later(product, 2)` and `perform_now`: the job's
    # arguments are checked against its perform's signature, then either
    # serialized as Active Job does and pushed onto Sidekiq's queue, or
    # passed to the job's `run` here and now.
    module JobCalls
      private

      def job_class(name, _node)
        Code["crate::jobs::#{Names.snake(name)}", T.job(name)]
      end

      def on_job(receiver, node, name, args)
        return nil unless %w[perform_later perform_now].include?(name)

        job = receiver.type.model
        need_ctx!(node)
        path = @app.job(job).dig("perform", "path")
        signature = Signatures.of(@app, path, @app.source.def_node(path, "perform"))
        if name == "perform_now"
          values = call_arguments(signature, args, node, "#{job}.#{name}", bind: :ctx)
          return Code["#{receiver.rust}::run(#{[ctx_mut, *values].join(", ")})?", T::UNIT, :write]
        end

        # Rails enqueues a nil record as nil; the job fails on it when it runs.
        signature = signature&.with(params: signature.params.map { _1.type.kind == :record ? _1.with(type: T.nilable(_1.type)) : _1 })
        values = call_arguments(signature, args, node, "#{job}.#{name}", bind: :ctx)
        @uses.rt("Json")
        arguments = values.zip(signature&.params || []).map do |value, param|
          # Active Job's JSON has no NaN or Infinity; Rails raises on them.
          next "rustonrails::jobs::float_argument(#{value})?" if [T::FLOAT, T.nilable(T::FLOAT)].include?(param.type)
          # Typed as declared: a bare None or a literal past i32 has no Rust
          # type of its own.
          next "{ let argument: #{param.type.rust} = #{value}; Json::from(argument) }" unless param.type.inner&.kind == :record

          # Named: a bare None leaves Rust no model to infer.
          use_model(param.type.inner.model)
          "rustonrails::jobs::record_argument::<#{param.type.inner.model}>(#{ctx_ref}, &crate::jobs::APP, #{value})?"
        end
        constant = Names.constant(Names.snake(job))
        @lines << "#{receiver.rust}::#{constant}.perform_later(&crate::jobs::APP, vec![#{arguments.join(", ")}])?;"
        Code["()", T::UNIT]
      end
    end
  end
end
