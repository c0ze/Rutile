require "rbs"

module Rutile
  module Build
    # A method's rbs-inline signature: its parameters in the def's order,
    # each with a type and a kind (:req, :opt, :key, :keyopt), and the
    # return type it declares (nil when it declares none).
    Signature = Data.define(:params, :returns) do
      def param(name) = params.find { _1.name == name }
      def positional = params.select { %i[req opt].include?(_1.kind) }
      def keywords = params.select { %i[key keyopt].include?(_1.kind) }
    end

    # One parameter; `default` is its literal default's node.
    Param = Data.define(:name, :type, :kind, :default)

    # rbs-inline comments above a def, read with the RBS parser:
    #
    #   #: (String, ?limit: Integer) -> Post?
    #   # @rbs (String) -> void
    #   # @rbs name: String
    #   # @rbs return: Integer
    #
    # The comments are Ruby's, so the code stays plain Ruby; Rutile reads
    # them as the types of the method's boundary (design.md, Types layer 3).
    module Signatures
      # RBS class names and what generated code holds for them.
      SCALARS = { "Integer" => T::INT, "Float" => T::FLOAT, "String" => T::STR, "Time" => T::TIME,
                  "ActiveSupport::TimeWithZone" => T::TIME, "Date" => T::DATE }.freeze
      RELATION = /\A(?:(\w+)::(?:ActiveRecord_Relation|ActiveRecord_Associations_CollectionProxy))\z/

      module_function

      # The signature of `node` (a DefNode) in `path`, or nil when it has
      # none. Unsupported for a signature Rutile can't use.
      def of(app, path, node)
        text = begin
          annotation(app.source.comments_above(path, node.location.start_line))
        rescue Overloaded
          raise Unsupported.at(path, node, "a method with more than one signature (an overload)")
        end
        return nil unless text

        method_type, named, returns = text
        params = parameters(node, path)
        signature = if method_type
                      from_method_type(app, path, node, params, method_type)
                    else
                      from_names(app, path, node, params, named, returns)
                    end
        signature.params.each { literal_default!(path, node, _1) }
        signature
      end

      # [method type string, { name => type string }, return type string]
      # from the comment lines, or nil when none is an annotation. A second
      # method type is an overload, which one Rust function can't be.
      def annotation(lines)
        method_types = []
        named = {}
        returns = nil
        lines.each do |line|
          body = line.sub(/\A#/, "")
          if body.start_with?(":")
            method_types << body.delete_prefix(":").strip
          elsif body.match?(/\A\s+\|/) && !method_types.empty?
            method_types << body.sub(/\A\s+\|/, "").strip
          elsif (rbs = body[/\A\s*@rbs\s+(.*)\z/, 1])
            rbs = rbs.sub(/\s+--\s.*\z/, "").strip
            if rbs.start_with?("(") then method_types << rbs
            elsif (m = rbs.match(/\Areturn:\s*(.+)\z/)) then returns = m[1]
            elsif (m = rbs.match(/\A(\w+):\s*(.+)\z/)) then named[m[1]] = m[2]
            end
          end
        end
        raise Overloaded if method_types.size > 1

        method_types.first || !named.empty? || returns ? [method_types.first, named, returns] : nil
      end

      # More than one method type above a def.
      class Overloaded < StandardError; end

      # The def's parameters as [name, kind, default node]; splats and
      # blocks are refused.
      def parameters(node, path)
        list = node.parameters or return []
        if list.rest || list.keyword_rest || list.block || !list.posts.empty?
          raise Unsupported.at(path, node, "a method with a splat or a block parameter")
        end

        raise Unsupported.at(path, node, "a destructuring parameter") unless list.requireds.all?(Prism::RequiredParameterNode)

        found = list.requireds.map { [_1.name.to_s, :req, nil] } + list.optionals.map { [_1.name.to_s, :opt, _1.value] } +
                list.keywords.map do |keyword|
                  keyword.is_a?(Prism::OptionalKeywordParameterNode) ? [keyword.name.to_s, :keyopt, keyword.value] : [keyword.name.to_s, :key, nil]
                end
        twice = found.map(&:first).tally.find { _2 > 1 }&.first
        raise Unsupported.at(path, node, "two parameters named #{twice}") if twice

        found
      end

      def from_method_type(app, path, node, params, text)
        function = parse(path, node) { RBS::Parser.parse_method_type(text, require_eof: true) }.type
        unless function.is_a?(RBS::Types::Function) && function.rest_positionals.nil? && function.rest_keywords.nil? &&
               function.trailing_positionals.empty?
          raise Unsupported.at(path, node, "the signature #{text}")
        end

        positional = function.required_positionals.map { [:req, _1] } + function.optional_positionals.map { [:opt, _1] }
        keywords = function.required_keywords.to_h { [_1.to_s, [:key, _2]] }.merge(function.optional_keywords.to_h { [_1.to_s, [:keyopt, _2]] })
        mismatch = -> { raise Unsupported.at(path, node, "a signature that doesn't match the def's parameters (#{text})") }
        typed = params.map do |name, kind, default|
          if %i[req opt].include?(kind)
            declared, param = positional.shift || mismatch.()
            mismatch.() unless declared == kind
          else
            declared, param = keywords.delete(name) || mismatch.()
            mismatch.() unless declared == kind
          end
          Param.new(name:, type: type(app, path, node, param.type), kind:, default:)
        end
        mismatch.() unless positional.empty? && keywords.empty?
        Signature.new(params: typed, returns: returns(app, path, node, function.return_type))
      end

      def from_names(app, path, node, params, named, returns)
        extra = named.keys - params.map(&:first)
        raise Unsupported.at(path, node, "@rbs for #{extra.join(", ")}, which the def doesn't take") unless extra.empty?

        typed = params.map do |name, kind, default|
          text = named[name] or raise Unsupported.at(path, node, "a signature without the parameter #{name}")
          Param.new(name:, type: type(app, path, node, parse(path, node) { RBS::Parser.parse_type(text, require_eof: true) }), kind:, default:)
        end
        declared = returns && returns(app, path, node, parse(path, node) { RBS::Parser.parse_type(returns, require_eof: true) })
        Signature.new(params: typed, returns: declared)
      end

      def parse(path, node)
        yield || raise(Unsupported.at(path, node, "an empty rbs-inline annotation"))
      rescue RBS::ParsingError => e
        raise Unsupported.at(path, node, "an rbs-inline annotation RBS can't parse (#{e.message.lines.first.strip})")
      end

      def returns(app, path, node, rbs)
        return T::UNIT if rbs.is_a?(RBS::Types::Bases::Void)

        type(app, path, node, rbs)
      end

      # What generated code holds for an RBS type.
      def type(app, path, node, rbs)
        case rbs
        when RBS::Types::Bases::Bool then T::BOOL
        when RBS::Types::Optional
          inner = type(app, path, node, rbs.type)
          return inner if inner == T::VALUE
          raise Unsupported.at(path, node, "the type #{rbs}") if inner.nilable?

          T.nilable(inner)
        when RBS::Types::ClassInstance then class_type(app, path, node, rbs)
        # A scalar whose class is known only at run time: the Value fallback.
        when RBS::Types::Bases::Any
          app.fallback(path, node, "untyped in the signature of #{node.name} falls back to Value")
          T::VALUE
        else raise Unsupported.at(path, node, "the type #{rbs}")
        end
      end

      def class_type(app, path, node, rbs)
        name = rbs.name.to_s.delete_prefix("::")
        args = rbs.args
        return SCALARS[name] if SCALARS.key?(name) && args.empty?
        return T.record(name) if app.model?(name) && args.empty?
        if name == "ActiveRecord::Relation" && args.size == 1 && args.first.is_a?(RBS::Types::ClassInstance) &&
           app.model?(args.first.name.to_s.delete_prefix("::"))
          return T.relation(args.first.name.to_s.delete_prefix("::"))
        end
        if (model = name[RELATION, 1]) && app.model?(model) && args.empty?
          return T.relation(model)
        end
        if name == "Array" && args.size == 1
          element = type(app, path, node, args.first)
          return T.list(element) if Blocks::ELEMENTS.include?((element.nilable? ? element.inner : element).kind)
        end
        raise Unsupported.at(path, node, "the type #{rbs}")
      end

      # A default Rutile can repeat at every call site: a literal of the
      # parameter's type, or nil for one that may be nil.
      def literal_default!(path, node, param)
        default = param.default or return
        want = param.type.nilable? ? param.type.inner : param.type
        fits = case default
               when Prism::NilNode then param.type.nilable? || want == T::VALUE
               when Prism::IntegerNode then [T::INT, T::VALUE].include?(want) && default.value.between?(-2**63, 2**63 - 1)
               when Prism::FloatNode then [T::FLOAT, T::VALUE].include?(want)
               when Prism::StringNode then [T::STR, T::VALUE].include?(want)
               when Prism::TrueNode, Prism::FalseNode then [T::BOOL, T::VALUE].include?(want)
               else false
               end
        raise Unsupported.at(path, node, "the default of #{param.name}, which isn't a literal of its type,") unless fits
      end
    end
  end
end
