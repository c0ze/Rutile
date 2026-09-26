module Rutile
  module Build
    # How Ruby names and literals are spelled in Rust.
    module Names
      ESCAPES = { '"' => '\\"', "\\" => "\\\\", "\n" => "\\n", "\r" => "\\r", "\t" => "\\t", "\0" => "\\0" }.freeze

      module_function

      # "PostsController" → "posts_controller"
      def snake(name) = name.to_s.gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase

      # "posts_controller" → "PostsController"
      def camel(name) = name.to_s.split("_").map(&:capitalize).join

      # An association's constant: "comments" → "COMMENTS"
      def constant(name) = name.to_s.upcase

      # `published?` → `is_published`, `find_by!` → `find_by_bang`, and a
      # keyword such as `ref` as the raw `r#ref`.
      def method(name)
        name = name.to_s
        return "is_#{name.delete_suffix("?")}" if name.end_with?("?")
        return "#{name.delete_suffix("!")}_bang" if name.end_with?("!")

        ident(name)
      end

      # A Ruby name that's a Rust keyword: a raw identifier, or a trailing
      # underscore for the ones that can't be raw.
      def ident(name)
        return name unless Translator::KEYWORDS.include?(name) || Translator::UNRAW.include?(name)

        Translator::UNRAW.include?(name) ? "#{name}_" : "r##{name}"
      end

      # The variable holding a model's record in its callbacks and methods:
      # `post`, or `match_record` for a model named like a keyword.
      def var(model)
        name = snake(model)
        Translator::KEYWORDS.include?(name) || Translator::UNRAW.include?(name) ? "#{name}_record" : name
      end

      # A string literal. Non-ASCII stays UTF-8, which Rust source allows.
      def str(value) = %("#{value.to_s.gsub(/["\\\n\r\t\0]/, ESCAPES)}")

      # A raw string literal, for regexp sources.
      def raw(value)
        hashes = "#" * ((value.scan(/"(#*)/).map { _1.first.size }.max || -1) + 1)
        %(r#{hashes}"#{value}"#{hashes})
      end

      # `&["id", "name"]`
      def str_slice(values) = "&[#{values.map { str(_1) }.join(", ")}]"

      # Rust source without its string literals, raw ones included.
      def code_only(rust) = rust.gsub(/r(#*)".*?"\1/m, "").gsub(/"(?:[^"\\]|\\.)*"/m, "\"\"")

      # Whether generated `lines` use the variable `name`, outside strings.
      # `self.name` is a field, not the variable; `..name` is a range.
      def mentions?(lines, name) = code_only(Array(lines).join("\n")).match?(/(?<![\w#])(?<![^.]\.)#{Regexp.escape(name)}\b/)

      # `lines` with `let mut` for a local of `locals` (Ruby's, by their
      # Rust names) that nothing assigns again in its scope: a local first
      # assigned in two blocks is `mut` for Ruby's count, not in either one.
      def needless_mut(lines, locals)
        text = lines.join("\n").split("\n")
        text.each_with_index.map do |line, i|
          name = line[/\A\s*let mut (\w+) = /, 1]
          next line unless name && locals.include?(name) && !assigned_after?(text, i, name)

          line.sub("let mut ", "let ")
        end
      end

      def assigned_after?(text, index, name)
        depth = 0
        text[(index + 1)..].any? do |line|
          code = code_only(line)
          assigned = code.match?(/(?<![\w.])#{Regexp.escape(name)} = /)
          depth += code.count("{") - code.count("}")
          break false if depth.negative? && !assigned

          assigned
        end
      end

      # `Ok(())` to end a body returning `Result<()>`, unless it ends by
      # returning already (a raise), where Rust would warn it's unreachable.
      def ended(lines) = lines.last.to_s.start_with?("return ") ? [] : ["Ok(())"]

      # Functions generated code calls unqualified, which a Rust variable
      # of the same name would shadow.
      FUNCTIONS = %w[action error_page error_response errors_json format_date format_time health local_today merge now
                     parse_query reason sanitize_sql_like sum_floats sum_integers today value_json].freeze

      # A parameter's Rust name: its own, unless Rust, the runtime or the
      # method's other names (`taken`) already mean something by it. `_`
      # can't be read in Rust, though Ruby reads it.
      def parameter(name, taken)
        return "_arg" if name == "_"

        (Translator::KEYWORDS + Translator::UNRAW + FUNCTIONS + taken).include?(name) ? "#{name}_" : name
      end
    end
  end
end
