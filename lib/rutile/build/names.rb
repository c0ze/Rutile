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

      # `published?` → `is_published`, `find_by!` → `find_by_bang`
      def method(name)
        name = name.to_s
        return "is_#{name.delete_suffix("?")}" if name.end_with?("?")
        return "#{name.delete_suffix("!")}_bang" if name.end_with?("!")

        name
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
    end
  end
end
