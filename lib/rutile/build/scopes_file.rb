module Rutile
  module Build
    # Scope traits. `scope :recent, -> { order(created_at: :desc) }` in
    # post.rb becomes `fn recent(self) -> Self` in `PostScopes`, implemented
    # for `Relation<Post>`, along with the scopes an enum defines. Scopes in
    # application_record.rb become one trait generic over every model.
    class Scopes
      APPLICATION_RECORD = "app/models/application_record.rb"

      # `model`'s own trait, or nil when it has no scopes of its own.
      def self.for_model(app, uses, model)
        path = app.model_path(model)
        mine = app.model(model)["scopes"].select { _1["origin"] == "framework" || _1.dig("source", "path") == path }
        foreign = app.model(model)["scopes"] - mine - app.model(model)["scopes"].select { _1.dig("source", "path") == APPLICATION_RECORD }
        unless foreign.empty?
          raise Unsupported, "#{path}: scope :#{foreign.first["name"]} from #{foreign.first.dig("source", "path")} isn't supported yet"
        end

        mine.empty? ? nil : new(app, uses, model, "#{model}Scopes", "Relation<#{model}>", "").to_rust(mine)
      end

      def initialize(app, uses, model, trait, target, generics)
        @app = app
        @uses = uses
        @model = model
        @trait = trait
        @target = target
        @generics = generics
      end

      def to_rust(scopes)
        @uses.rt("Relation")
        items = scopes.filter_map do |scope|
          @app.attempt { scope["origin"] == "framework" ? enum_scope(scope["name"]) : lambda_scope(scope) }
        end
        "pub trait #{@trait} {\n#{items.map(&:first).join("\n")}\n}\n\n" \
          "impl#{@generics} #{@trait} for #{@target} {\n#{items.map(&:last).join("\n\n")}\n}"
      end

      private

      # `draft` and `not_draft` from `enum :status, { draft: 0, ... }`.
      def enum_scope(name)
        enums = @app.model(@model)["enums"]
        label, method = enums.values.any? { _1.key?(name) } ? [name, "where_eq"] : [name.delete_prefix("not_"), "where_not"]
        attribute, = enums.find { |_, values| values.key?(label) }
        raise Unsupported, "#{@app.model_path(@model)}: framework scope :#{name} isn't supported yet" unless attribute

        ["fn #{name}(self) -> Self;", "fn #{name}(self) -> Self {\nself.#{method}(#{Names.str(attribute)}, #{Names.str(label)})\n}"]
      end

      def lambda_scope(scope)
        path, line = scope["source"].values_at("path", "line")
        node = @app.source.block_at(path, line)
        raise Unsupported.at(path, node, "a scope body that isn't a lambda") unless node.is_a?(Prism::LambdaNode)

        names = parameters(node, path)
        types = parameter_types(node, names, path)
        translator = Translator.new(@app, path, @uses, env: :scope, model: @model, result: false)
        # A Ruby name that's a Rust keyword becomes a raw identifier.
        rust = names.to_h { [_1, rust_name(_1)] }
        names.each { translator.declare(_1, rust[_1], types.fetch(_1)) }
        lines, type = translator.body(node.body, :value)
        raise Unsupported.at(path, node, "a scope that doesn't return a relation") unless type.kind == :relation

        @uses.rt("Time") if types.value?(T::TIME)
        signature = "fn #{scope["name"]}(self#{names.map { ", #{rust[_1]}: #{types[_1].rust}" }.join})"
        ["#{signature} -> Self;", "// #{path}:#{line}\n#{signature} -> Self {\n#{lines.join("\n")}\n}"]
      end

      # A Ruby name that's a Rust keyword: a raw identifier, or a trailing
      # underscore for the ones that can't be raw.
      def rust_name(name)
        return name unless Translator::KEYWORDS.include?(name) || Translator::UNRAW.include?(name)

        Translator::UNRAW.include?(name) ? "#{name}_" : "r##{name}"
      end

      def parameters(node, path)
        params = node.parameters&.parameters or return []
        plain = params.optionals.empty? && params.posts.empty? && params.keywords.empty? &&
                params.rest.nil? && params.keyword_rest.nil? && params.block.nil? &&
                params.requireds.all?(Prism::RequiredParameterNode)
        raise Unsupported.at(path, node, "scope parameters other than plain ones") unless plain

        params.requireds.map { _1.name.to_s }
      end

      # A parameter compared with a column in `where` has the column's type.
      def parameter_types(node, names, path)
        types = {}
        each_where_pair(node) do |column, value|
          value = value.left if value.is_a?(Prism::RangeNode)
          next unless value.is_a?(Prism::LocalVariableReadNode) && names.include?(value.name.to_s)

          types[value.name.to_s] ||= @app.column_type(@model, column)
        end
        missing = names - types.compact.keys
        raise Unsupported.at(path, node, "a scope parameter (#{missing.join(", ")}) not compared with a column") unless missing.empty?

        types
      end

      def each_where_pair(node, &block)
        if node.is_a?(Prism::CallNode) && node.name == :where
          (node.arguments&.arguments || []).each do |arg|
            next unless arg.is_a?(Prism::KeywordHashNode) || arg.is_a?(Prism::HashNode)

            arg.elements.each { yield _1.key.unescaped, _1.value if _1.is_a?(Prism::AssocNode) && _1.key.is_a?(Prism::SymbolNode) }
          end
        end
        node.compact_child_nodes.each { each_where_pair(_1, &block) }
      end
    end

    # src/models/application_record.rs: the scopes every model inherits.
    class ApplicationRecordFile
      def initialize(app)
        @app = app
        @uses = Uses.new
      end

      # [scope, a model that has it], once per scope name.
      def scopes
        found = {}
        @app.models.each do |model|
          model["scopes"].each do |scope|
            found[scope["name"]] ||= [scope, model["name"]] if scope.dig("source", "path") == Scopes::APPLICATION_RECORD
          end
        end
        found.values
      end

      def empty? = scopes.empty?

      # Any model that has the scope types its parameters: the columns come
      # from the table every model shares the shape of.
      def to_rust
        Declarations.check(@app, Scopes::APPLICATION_RECORD, Declarations::MODEL)
        entries = scopes
        @uses.rt("Model")
        traits = Scopes.new(@app, @uses, entries.first.last, "ApplicationRecordScopes", "Relation<M>", "<M: Model>")
                       .to_rust(entries.map(&:first))
        header = "//! Generated by Rutile from #{Scopes::APPLICATION_RECORD}. Edit the Ruby, not this file."
        [header, @uses.lines("super"), traits].join("\n\n") + "\n"
      end
    end
  end
end
