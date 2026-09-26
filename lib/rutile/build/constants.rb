module Rutile
  module Build
    # Constants a class body assigns a literal: `PER_PAGE = 20`. Ruby looks a
    # constant up in the class whose method reads it, then in the class that
    # one inherits from: a controller method sees its class's constants and
    # then ApplicationController's, a model method its model's and then
    # ApplicationRecord's. Each one read becomes a Rust `const` in the file.
    module Constants
      PARENTS = { controller: "app/controllers/application_controller.rb", model: "app/models/application_record.rb",
                  job: "app/jobs/application_job.rb",
                  scope: "app/models/application_record.rb", normalizer: "app/models/application_record.rb" }.freeze

      private

      def constant(node)
        name = node.name.to_s
        klass = { "Time" => T::TIME_CLASS, "Date" => T::DATE_CLASS }[name]
        return Code[name, klass] if klass

        home = [@path, PARENTS[@env]].compact.uniq.find { assignments(_1).key?(name) }
        return class_constant(name, home, node) if home

        return job_class(name, node) if @app.job(name)
        if @app.manifest.dig("jobs", "classes")&.any? { _1["name"] == name }
          unsupported!(node, "#{name} on the #{@app.manifest.dig("jobs", "adapter")} queue adapter; jobs run on Sidekiq's")
        end

        unsupported!(node, "the constant #{name}") unless @app.model?(name)
        use_model(name)
        Code[name, T.klass(name)]
      end

      def class_constant(name, path, node)
        assignment = assignments(path)[name]
        type, rust_type, value = literal_constant(assignment.value) ||
                                 unsupported!(node, "#{name}, a constant that isn't an integer, string or boolean")
        rust = Names.constant(Names.snake(name))
        item = "// #{path}:#{assignment.location.start_line}\nconst #{rust}: #{rust_type} = #{value};"
        @uses.constant(rust, item) || unsupported!(node, "#{name}, which means two things in this file")
        type == T::STR ? Code[rust, type, literal: true] : Code[rust, type]
      end

      # name => its last assignment in the file's class body. A file with
      # more than one class has none: which class a constant is in is
      # beyond this.
      def assignments(path)
        @assignments ||= {}
        @assignments[path] ||= begin
          classes = @app.source.exist?(path) ? Declarations.classes(@app.source.tree(path)) : []
          body = classes.size == 1 ? classes.first.body : nil
          statements = body.is_a?(Prism::StatementsNode) ? body.body : []
          statements.grep(Prism::ConstantWriteNode).to_h { [_1.name.to_s, _1] }
        end
      end

      # [type, Rust type, Rust value] of a literal, frozen or not.
      def literal_constant(value)
        value = value.receiver if value.is_a?(Prism::CallNode) && value.name == :freeze && value.receiver && !value.arguments
        case value
        when Prism::IntegerNode then [T::INT, "i64", value.value.to_s] if value.value.bit_length < 64
        when Prism::StringNode, Prism::SymbolNode then [T::STR, "&str", Names.str(value.unescaped)]
        when Prism::TrueNode, Prism::FalseNode then [T::BOOL, "bool", value.is_a?(Prism::TrueNode).to_s]
        end
      end
    end
  end
end
