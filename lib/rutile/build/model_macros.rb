module Rutile
  module Build
    # `normalizes` and `has_secure_token`, as introspection records them:
    # a normalizer is the app's lambda, translated into a function on the
    # model; a token is a Behavior entry, or a before_create hook for
    # `on: :create`.
    module ModelMacros
      module_function

      # The Rust path of the function normalizing `attribute`: nil when it
      # has none, Skipped when the model file refuses it (and reports why).
      def normalizer(app, model, attribute)
        chain = app.normalization(model, attribute) or return nil
        raise Skipped, "normalizes :#{attribute}" if problem(app, model, attribute, chain)

        "#{model}::#{function(attribute)}"
      end

      def function(attribute) = "normalize_#{attribute}"

      # Why a normalization can't compile, or nil. `chain` holds one entry
      # per `normalizes` naming the attribute.
      def problem(app, model, attribute, chain)
        return "normalizes :#{attribute} more than once" if chain.size > 1

        options = chain.first
        return "normalizes :#{attribute} with apply_to_nil" if options["apply_to_nil"]
        return "normalizes :#{attribute} with a normalizer that isn't a lambda in the app" unless options.dig("with", "proc")
        return "normalizes :#{attribute}, which isn't a column" unless app.column(model, attribute)
        return "normalizes on the enum #{attribute}" if app.enum(model, attribute)
        return "normalizes on the belongs_to key #{attribute}" if foreign_key?(app, model, attribute)

        type = app.column_type(model, attribute)
        return "normalizes on the #{type.kind} column #{attribute}" unless type == T::STR

        taken = app.source.defs(app.model_path(model)).find { Names.method(_1.name) == function(attribute) }
        "normalizes :#{attribute}, whose function #{function(attribute)} the method #{taken.name} would clash with," if taken
      end

      def foreign_key?(app, model, attribute)
        app.model(model)["associations"].any? { _1["macro"] == "belongs_to" && _1["foreign_key"] == attribute }
      end

      # `->(email) { email.strip.downcase }` as `pub fn normalize_email(email:
      # String) -> String`. It can't fail: the runtime normalizes query
      # values, which have no error path.
      def translate(app, model, attribute, chain, uses)
        path = app.model_path(model)
        problem = problem(app, model, attribute, chain)
        raise Unsupported, "#{path}: #{problem} isn't supported yet" if problem

        location = chain.first["with"]["proc"]
        node = app.source.block_at(location["path"], location["line"])
        params = node.parameters.is_a?(Prism::BlockParametersNode) && node.parameters.parameters
        plain = params && params.requireds.size == 1 && params.requireds.first.is_a?(Prism::RequiredParameterNode) &&
                params.optionals.empty? && params.posts.empty? && params.keywords.empty? && !params.rest &&
                !params.keyword_rest && !params.block
        raise Unsupported.at(location["path"], node, "a normalizer without one plain parameter") unless plain

        name = params.requireds.first.name.to_s
        rust = Translator::KEYWORDS.include?(name) || %w[self ctx req].include?(name) ? "value" : name
        translator = Translator.new(app, location["path"], uses, env: :normalizer, model:, result: false)
        translator.declare(name, rust, T::STR)
        lines, type = translator.body(node.body, :value)
        raise Unsupported.at(location["path"], node, "a normalizer returning #{type.kind}") unless type == T::STR
        raise Unsupported.at(location["path"], node, "a normalizer that can fail") if fallible?(lines)

        parameter = Names.mentions?(lines, rust) ? rust : "_#{rust}"
        "// normalizes :#{attribute} (#{location["path"]}:#{location["line"]})\n" \
          "pub fn #{function(attribute)}(#{parameter}: String) -> String {\n#{lines.join("\n")}\n}"
      end

      # A `?` outside string literals.
      def fallible?(lines) = Names.code_only(lines.join("\n")).include?("?")

      # Whether the model generates a token when a record is built.
      def initialize_tokens?(app, model)
        (app.model(model)["callbacks"]["initialize"] || []).any? { _1.dig("filter", "secure_token") }
      end

      # The token entry of a chain, with its Behavior line: `on: :initialize`
      # is Behavior's own; `on: :create` is a before_create hook in its slot.
      def token(entry, event, path, var)
        token = entry.dig("filter", "secure_token") or return nil
        attribute, length = token.values_at("attribute", "length")
        unless entry["if"].empty? && entry["unless"].empty?
          raise Unsupported, "#{path}: has_secure_token :#{attribute} with conditions isn't supported yet"
        end

        comment = "// has_secure_token :#{attribute}#{", on: :create" if event == "create"}"
        case [event, entry["kind"]]
        when %w[initialize after] then [comment, ".has_secure_token(#{Names.str(attribute)}, #{length})"]
        when %w[create before]
          [comment, ".before_create(|ctx, #{var}| ctx.fill_secure_token(#{var}, #{Names.str(attribute)}, #{length}))"]
        else raise Unsupported, "#{path}: has_secure_token :#{attribute} on #{entry["kind"]}_#{event} isn't supported yet"
        end
      end
    end
  end
end
