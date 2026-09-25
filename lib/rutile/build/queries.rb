module Rutile
  module Build
    # A relation's query methods: where (on the model's columns or a joined
    # table's), order, limit, offset, joins and includes. Each keeps the SQL
    # Rails would run or is refused. A relation's Code carries the tables it
    # joins in `extra[:joined]` (table => model).
    module Queries
      SCALARS = %i[str int float bool time value].freeze

      private

      # The next relation in a chain.
      def relation(receiver, rust, *codes)
        Code[rust, T.relation(receiver.type.model), touch(receiver, *codes), hint: receiver.hint, **receiver.extra.slice(:joined)]
      end

      # `where(status: :done, memberships: { user_id: id })`: a hash value
      # names a table the relation joins, by association or by table name.
      def where_pairs(receiver, model, args, node)
        joined = receiver.extra[:joined] || {}
        receiver, conditions = after(receiver) do
          pairs(args, node).flat_map do |key, operand|
            next [condition(model, key, operand, node)] unless hash?(operand)

            target = joined_model(model, key, joined, node)
            pairs([operand], node).map { |column, value| joined_condition(target, column, value, node) }
          end
        end
        relation(receiver, "#{receiver.rust}#{conditions.map(&:first).join}", *conditions.map(&:last))
      end

      # [Rust, Code] for one condition on the model's own column.
      def condition(model, column, operand, node)
        if operand.is_a?(Prism::RangeNode)
          unsupported!(node, "a where range other than `x..`") unless operand.left && operand.right.nil? && !operand.exclude_end?
          bound = value(operand.left)
          unsupported!(node, "a where range from a value that may be nil") if bound.type.nilable?
          return [".where_gte(#{Names.str(column)}, #{owned(bound)})", bound]
        end
        unsupported!(node, "where on #{column}, which #{model} doesn't have") unless @app.column_type(model, column)
        code = value(operand)
        bindable!(code, node, "where")
        [".where_eq(#{Names.str(column)}, #{where_value(code)})", code]
      end

      def joined_condition(target, column, operand, node)
        unsupported!(node, "where on #{column}, which #{target} doesn't have") unless @app.column_type(target, column)
        unsupported!(node, "a where range on a joined table") if operand.is_a?(Prism::RangeNode)
        code = value(operand)
        bindable!(code, node, "where")
        use_model(target)
        [".where_on::<#{target}>(#{Names.str(column)}, #{where_value(code)})", code]
      end

      def joined_model(model, key, joined, node)
        assoc = @app.association(model, key)
        table = assoc ? @app.model(assoc["class_name"])["table_name"] : key
        joined[table] || unsupported!(node, "where on #{key}, which the relation doesn't join")
      end

      # nil is SQL's NULL; so is a value that turns out nil.
      def where_value(code)
        return owned(code) unless code.type == T::NIL

        @uses.rt("Value")
        "Value::Nil"
      end

      # What a query can bind: a scalar, or one that may be nil.
      def bindable!(code, node, what)
        kind = code.type.nilable? ? code.type.inner.kind : code.type.kind
        unsupported!(node, "#{what} with #{describe(code.type)}") unless SCALARS.include?(kind) || code.type == T::NIL
      end

      def order(args, node)
        args.flat_map do |arg|
          next [".order_asc(#{Names.str(symbol!(arg, node))})"] if arg.is_a?(Prism::SymbolNode)

          pairs([arg], node).map do |column, direction|
            dir = symbol!(direction, node)
            unsupported!(node, "order direction :#{dir}") unless %w[asc desc].include?(dir)
            ".order_#{dir}(#{Names.str(column)})"
          end
        end.join
      end

      # `limit(n)`, `offset(n)`: an Integer, read after the relation.
      def paginate(receiver, name, args, node)
        receiver, count = after(receiver) { value(only(args, node)) }
        unsupported!(node, "#{name} with #{describe(count.type)}") unless count.type == T::INT
        relation(receiver, "#{receiver.rust}.#{name}(#{count.rust})", count)
      end

      # `joins(:project)`, `joins(project: :memberships)`: inner joins along
      # belongs_to and has_many, each table once, since Rails would alias a
      # second one.
      def joins(receiver, model, args, node)
        joined = (receiver.extra[:joined] || {}).dup
        steps = args.flat_map do |arg|
          next [[model, symbol!(arg, node)]] unless hash?(arg)

          pairs([arg], node).flat_map do |name, nested|
            target = join_target(model, name, node)
            [[model, name], *symbols(nested, node).map { [target, _1] }]
          end
        end
        rust = steps.map do |owner, name|
          target = join_target(owner, name, node)
          table = @app.model(target)["table_name"]
          unsupported!(node, "joining #{table} twice") if table == @app.model(model)["table_name"] || joined.key?(table)
          joined[table] = target
          use_model(owner)
          ".joins(&#{owner}::#{Names.constant(name)})"
        end
        Code["#{receiver.rust}#{rust.join}", T.relation(model), receiver.ctx, hint: receiver.hint, joined:]
      end

      def join_target(owner, name, node)
        assoc = @app.association(owner, name) or unsupported!(node, "joins(:#{name}), which #{owner} doesn't have")
        through = assoc["options"]["through"]
        extra = assoc["options"].keys - ModelFile::ASSOCIATION_OPTIONS
        unless %w[belongs_to has_many].include?(assoc["macro"]) && !through && extra.empty?
          unsupported!(node, "joins(:#{name}), a #{assoc["macro"]}#{" through #{through}" if through}" \
                             "#{" with #{extra.join(", ")}" unless extra.empty?}")
        end
        assoc["class_name"]
      end

      # Preloading a through association isn't built yet.
      def include_one(model, name, node)
        through = @app.association(model, name)&.dig("options", "through")
        unsupported!(node, "including #{name} through #{through}") if through
        ".includes(&#{model}::#{Names.constant(name)})"
      end

      # `where("title ILIKE ?", pattern)`: a SQL fragment with one bind per
      # `?`, as Rails' sanitize_sql_array counts them.
      def where_sql(receiver, args, node)
        sql = args.first.unescaped
        binds = args.drop(1)
        unless sql.count("?") == binds.size
          unsupported!(node, "a SQL fragment with #{sql.count("?")} ? and #{binds.size} value#{"s" unless binds.size == 1}")
        end
        # Its binds become $1, $2, ...; a $ of its own would collide.
        unsupported!(node, "a SQL fragment with $") if sql.include?("$")
        receiver, codes = after(receiver) { in_order(binds) { value(_1) } }
        codes.each { bindable!(_1, node, "a SQL bind") }
        list = codes.map { "#{where_value(_1)}.into()" }
        relation(receiver, "#{receiver.rust}.where_sql(#{Names.str(sql)}, vec![#{list.join(", ")}])", *codes)
      end

      # `sanitize_sql_like(query)`, with Rails' default escape character.
      def sanitize_like(args, node)
        code = value(only(args, node))
        unsupported!(node, "sanitize_sql_like with #{describe(code.type)}") unless code.type == T::STR
        @uses.rt("sanitize_sql_like")
        Code["sanitize_sql_like(#{code.extra[:literal] ? code.rust : "&#{code.rust}"})", T::STR, code.ctx]
      end
    end
  end
end
