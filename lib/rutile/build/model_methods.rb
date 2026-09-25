module Rutile
  module Build
    # A model's own instance methods, each translated once and shared: the
    # model file emits them, and callers anywhere learn their return types.
    # A public method is compiled whether or not anything calls it, since
    # the app may; a private one only when a method of its model calls it.
    class ModelMethods
      # Associated functions `Model` and `Record` define, which an inherent
      # function of the same name would shadow.
      RESERVED = %w[all find find_by find_by_bang from_attributes create create_bang insert behavior new_record get set
                    cast_query before_type_cast before_type_cast_mut id default clone eq ne fmt].freeze
      # What a method may return: the types with a Rust spelling.
      RETURNABLE = %i[record relation nilable str int float bool time date value json attributes unit].freeze

      Entry = Struct.new(:model, :name, :node, :visibility, :state, :type, :rust, :uses)

      def initialize(app)
        @app = app
        @entries = {}
        @visibilities = {}
      end

      # The model's `def name` and its visibility, or nil.
      def definition(model, name) = visibilities(@app.model_path(model))[name.to_s]

      # A callback method, which the model file compiles as a hook.
      def hook?(model, name)
        @app.model(model)["callbacks"].values.flatten.any? { _1.dig("filter", "method") == name.to_s }
      end

      # The return type of `model#name`, translated the first time it's
      # asked for. `at` is the calling file and node, for the error.
      def type(model, name, at)
        found = entry(model, name) or raise Error, "#{model} has no method #{name}"
        raise Unsupported.at(*at, "calling #{name}, which is also a callback,") if hook?(model, name)
        raise Unsupported.at(*at, "#{name} calling itself") if found.state == :working

        translate(found) unless found.state
        raise Skipped, name if found.state == :failed

        found.type
      end

      def private?(model, name) = definition(model, name)&.last != :public

      # Every public method but the callbacks, for the model file.
      def publics(model)
        visibilities(@app.model_path(model)).select { |name, (_, v)| v == :public && !hook?(model, name) }.keys
      end

      # What the model file emits, in source order.
      def translated(model)
        @entries.values.select { _1.model == model && _1.state == :done }.sort_by { _1.node.location.start_line }
      end

      private

      def entry(model, name)
        @entries[[model, name.to_s]] ||= begin
          node, visibility = definition(model, name)
          node && Entry.new(model:, name: name.to_s, node:, visibility:)
        end
      end

      def translate(entry)
        entry.state = :working
        entry.state = @app.attempt(:failed) do
          compile(entry)
          :done
        end
      end

      def compile(entry)
        path = @app.model_path(entry.model)
        node = entry.node
        raise Unsupported.at(path, node, "a model method with parameters") if node.parameters
        raise Unsupported.at(path, node, "the #{entry.visibility} method #{entry.name}") if entry.visibility == :protected
        unless entry.name.match?(/\A[a-z_][a-z0-9_]*[?!]?\z/) && !RESERVED.include?(Names.method(entry.name))
          raise Unsupported.at(path, node, "a model method named #{entry.name}")
        end
        if @app.enum_predicate(entry.model, entry.name) || @app.enum_bang(entry.model, entry.name)
          raise Unsupported.at(path, node, "#{entry.name}, which redefines an enum method,")
        end

        var = Names.snake(entry.model)
        entry.uses = Uses.new
        translator = Translator.new(@app, path, entry.uses, env: :model, model: entry.model, self_var: var)
        lines, type = translator.body(node.body, :value)
        raise Unsupported.at(path, node, "a model method returning #{type.kind}") unless RETURNABLE.include?(type.kind)

        entry.uses.type(type)
        entry.uses.rt("Ctx", "Handle", "Result")
        entry.type = type
        text = lines.join("\n")
        ctx = text.match?(/\bctx\b/) ? "ctx" : "_ctx"
        record = text.match?(/\b#{var}\b/) ? var : "_#{var}"
        entry.rust = "// #{path}:#{node.location.start_line}\n#{"pub " if entry.visibility == :public}" \
                     "fn #{Names.method(entry.name)}(#{ctx}: &mut Ctx, #{record}: Handle<#{entry.model}>) -> Result<#{type.rust}> " \
                     "{\n#{text}\n}"
      end

      # name => [def node, visibility] for the defs in the file's class
      # body, following `private` and `private def ...`. Singleton methods
      # aren't instance methods.
      def visibilities(path)
        @visibilities[path] ||= begin
          classes = Declarations.classes(@app.source.tree(path))
          body = classes.size == 1 ? classes.first.body : nil
          current = :public
          (body.is_a?(Prism::StatementsNode) ? body.body : []).each_with_object({}) do |node, found|
            if node.is_a?(Prism::DefNode) && node.receiver.nil?
              found[node.name.to_s] = [node, current]
            elsif node.is_a?(Prism::CallNode) && node.receiver.nil? && %i[private protected public].include?(node.name)
              args = node.arguments&.arguments || []
              current = node.name if args.empty?
              args.each do |arg|
                found[arg.name.to_s] = [arg, node.name] if arg.is_a?(Prism::DefNode)
                found[arg.unescaped] = [found[arg.unescaped].first, node.name] if arg.is_a?(Prism::SymbolNode) && found[arg.unescaped]
              end
            end
          end
        end
      end
    end
  end
end
