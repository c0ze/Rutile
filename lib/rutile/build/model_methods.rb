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

      Entry = Struct.new(:model, :name, :node, :visibility, :state, :type, :rust, :uses, :signature)

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
        # Ruby stops runaway recursion with SystemStackError, a 500; a Rust
        # stack overflow aborts the whole server.
        if found.state == :working
          raise Unsupported.at(*at, "#{name} calling itself, directly or through another method,")
        end

        translate(found) unless found.state
        raise Skipped, name if found.state == :failed

        found.type
      end

      def private?(model, name) = definition(model, name)&.last != :public

      # How the class at `path` declares `name`, a def or an attr_reader:
      # :public, :private or :protected, or nil if it doesn't.
      def visibility(path, name)
        defs, readers, named = declared(path)
        defs[name.to_s]&.last || readers[name.to_s] || named[name.to_s]
      end

      # The signature of a method `type` has translated, or nil.
      def signature(model, name) = entry(model, name)&.signature

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
        raise Unsupported.at(path, node, "the #{entry.visibility} method #{entry.name}") if entry.visibility == :protected
        unless entry.name.match?(/\A[a-z_][a-z0-9_]*[?!]?\z/) && !RESERVED.include?(Names.method(entry.name))
          raise Unsupported.at(path, node, "a model method named #{entry.name}")
        end
        if @app.enum_predicate(entry.model, entry.name) || @app.enum_bang(entry.model, entry.name)
          raise Unsupported.at(path, node, "#{entry.name}, which redefines an enum method,")
        end
        if (clash = rails_method(entry.model, entry.name))
          raise Unsupported.at(path, node, "#{entry.name}, which replaces #{clash},")
        end
        if generated_names(entry.model).include?(Names.method(entry.name))
          raise Unsupported.at(path, node, "#{entry.name}, whose Rust name #{Names.method(entry.name)} Rutile gives something else,")
        end

        signature = entry.signature = Signatures.of(@app, path, node)
        raise Unsupported.at(path, node, "a model method with parameters and no rbs-inline signature") if node.parameters && !signature

        var = Names.var(entry.model)
        entry.uses = Uses.new
        declared = signature&.returns
        entry.type = declared
        translator = Translator.new(@app, path, entry.uses, env: :model, model: entry.model, self_var: var,
                                                           returns: declared == T::UNIT ? nil : declared)
        params = (signature&.params || []).map do |param|
          rust = parameter_name(param.name, var)
          translator.declare(param.name, rust, param.type)
          entry.uses.type(param.type)
          [rust, param.type]
        end
        tail = declared == T::UNIT ? :unit : :value
        lines, type = translator.body(node.body, tail)
        lines.concat(Names.ended(lines)) if tail == :unit
        type = declared || type
        raise Unsupported.at(path, node, "a model method returning #{type.kind}") unless RETURNABLE.include?(type.kind)

        entry.uses.type(type)
        entry.uses.rt("Ctx", "Handle", "Result")
        entry.type = type
        entry.rust = emit(entry, lines, params, var, type)
      end

      def emit(entry, lines, params, var, type)
        path = @app.model_path(entry.model)
        text = lines.join("\n")
        used = ->(name) { Names.mentions?(text, name) ? name : "_#{name}" }
        arguments = ["#{used.("ctx")}: &mut Ctx", "#{used.(var)}: Handle<#{entry.model}>",
                     *params.map { |rust, param_type| "#{used.(rust)}: #{param_type.rust}" }]
        "// #{path}:#{entry.node.location.start_line}\n#{"pub " if entry.visibility == :public}" \
          "fn #{Names.method(entry.name)}(#{arguments.join(", ")}) -> Result<#{type.rust}> {\n#{text}\n}"
      end

      # A parameter's Rust name: its own, unless Rust or the method's other
      # names already mean something by it.
      def parameter_name(name, var) = Names.parameter(name, ["ctx", "req", "self", var])

      # What Rails' own code would call instead of Rutile's calls: a column
      # or association reader, or a method of Active Record's. Nil if none.
      def rails_method(model, name)
        return "Active Record's #{name}" if @app.overrides(model).any? { _1["name"] == name }
        return "the #{name} column's reader" if @app.column(model, name)

        "the #{name} association's reader" if @app.association(model, name)
      end

      # Functions the model file generates on its own: enum predicates and
      # normalizers.
      def generated_names(model)
        enums = @app.model(model)["enums"].values.flat_map { |values| values.keys.map { "is_#{_1}" } }
        enums + @app.model(model)["normalizations"].keys.map { ModelMacros.function(_1) }
      end

      # name => [def node, visibility] for the defs in the file's class
      # body, following `private` and `private def ...`. Singleton methods
      # aren't instance methods.
      def visibilities(path) = declared(path).first

      # The class body's defs, its readers (attr_reader and attr_accessor)
      # and the names `private :name` sets for neither, which are inherited
      # methods, in one pass: `private :name` and `public %i[name]` change
      # any of them, and `private attr_reader :x` declares a reader.
      def declared(path)
        @visibilities[path] ||= begin
          defs = {}
          readers = {}
          named = {}
          current = :public
          class_body(path).each do |node|
            if node.is_a?(Prism::DefNode) && node.receiver.nil?
              defs[node.name.to_s] = [node, current]
            elsif attr?(node)
              attr_names(node).each { readers[_1] = current }
            elsif node.is_a?(Prism::CallNode) && node.receiver.nil? && %i[private protected public].include?(node.name)
              args = node.arguments&.arguments || []
              current = node.name if args.empty?
              args.flat_map { _1.is_a?(Prism::ArrayNode) ? _1.elements : [_1] }.each do |arg|
                if arg.is_a?(Prism::DefNode)
                  defs[arg.name.to_s] = [arg, node.name]
                elsif attr?(arg)
                  attr_names(arg).each { readers[_1] = node.name }
                elsif arg.is_a?(Prism::SymbolNode) || arg.is_a?(Prism::StringNode)
                  name = arg.unescaped
                  if defs[name] then defs[name] = [defs[name].first, node.name]
                  elsif readers[name] then readers[name] = node.name
                  else named[name] = node.name
                  end
                else raise Unsupported.at(path, node, "#{node.name} with an argument that isn't a name or a def")
                end
              end
            end
          end
          [defs, readers, named]
        end
      end

      def attr?(node) = node.is_a?(Prism::CallNode) && node.receiver.nil? && %i[attr_reader attr_accessor].include?(node.name)

      def attr_names(node)
        (node.arguments&.arguments || []).filter_map { _1.unescaped if _1.is_a?(Prism::SymbolNode) || _1.is_a?(Prism::StringNode) }
      end

      # The statements of the file's one class body.
      def class_body(path)
        classes = Declarations.classes(@app.source.tree(path))
        body = classes.size == 1 ? classes.first.body : nil
        body.is_a?(Prism::StatementsNode) ? body.body : []
      end
    end
  end
end
