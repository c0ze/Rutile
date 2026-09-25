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
      def mentions?(lines, name) = code_only(Array(lines).join("\n")).match?(/(?<![\w#])#{Regexp.escape(name)}\b/)
    end
  end
end
