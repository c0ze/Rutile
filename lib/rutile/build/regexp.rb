module Rutile
  module Build
    # Ruby (Onigmo) regexps as Rust `regex` patterns that accept the same
    # strings. Ruby's shorthand classes are ASCII where Rust's are Unicode
    # (but `\b` is Unicode in both), Ruby's `^` and `$` always match at line
    # breaks, and Rust has no look-around, backreferences, atomic groups or
    # possessive quantifiers. Spaces are written `\x20` so that `(?x)`, which
    # in Rust drops whitespace inside a class too, keeps them.
    module RubyRegexp
      OUTSIDE = { "d" => "[0-9]", "D" => "[^0-9]", "w" => "[a-zA-Z0-9_]", "W" => "[^a-zA-Z0-9_]",
                  "s" => '[\x20\t\n\x0B\x0C\r]', "S" => '[^\x20\t\n\x0B\x0C\r]', "h" => "[0-9a-fA-F]",
                  "H" => "[^0-9a-fA-F]", "b" => '\b', "B" => '\B', "Z" => '\n?\z', "e" => '\x1B', "0" => '\x00' }.freeze
      INSIDE = { "d" => "0-9", "w" => "a-zA-Z0-9_", "s" => '\x20\t\n\x0B\x0C\r', "h" => "0-9a-fA-F", "e" => '\x1B',
                 "0" => '\x00' }.freeze
      # Escapes both engines read the same way.
      KEPT = %w[A z n t r f v a x u U p P].freeze
      FLAGS = { 1 => "i", 2 => "x", 4 => "s" }.freeze

      module_function

      def to_rust(source, options, path)
        refuse = ->(what) { raise Unsupported, "#{path}: #{what} in a regexp isn't supported yet" }
        refuse.("the options #{options}") unless (options & ~7).zero?
        flags = FLAGS.select { |bit, _| options.anybits?(bit) }.values
        out = +""
        depth = 0
        quantified = false
        i = 0
        while i < source.size
          c = source[i]
          if c == "\\"
            i = escape(source, i, depth, out, refuse)
            quantified = false
            next
          end
          if depth.positive? && c.match?(/\s/)
            # Literal in a Ruby class even under /x; Rust's (?x) drops it.
            out << format("\\x{%X}", c.ord)
            i += 1
            next
          end
          if depth.positive?
            refuse.("a POSIX bracket") if c == "[" && source[i + 1] == ":"
            depth += 1 if c == "["
            depth -= 1 if c == "]"
          else
            case c
            when "[" then depth += 1
            when "^", "$" then flags << "m" unless flags.include?("m")
            when "("
              group = source[i + 1..][/\A\?([imx-]+)([:)])/]
              if group
                out << group.tr("m", "s").prepend("(")
                i += group.size + 1
                next
              end
              rest = source[i + 1..]
              refuse.("look-around") if rest.match?(/\A\?<?[=!]/)
              refuse.("an atomic group") if rest.start_with?("?>")
              refuse.("a comment group") if rest.start_with?("?#")
              refuse.("a group named in quotes") if rest.start_with?("?'")
            when "*", "+", "?"
              refuse.("a possessive quantifier") if c == "+" && quantified
              out << c
              quantified = !(quantified && c == "?")
              i += 1
              next
            when "}"
              out << c
              quantified = true
              i += 1
              next
            end
          end
          out << c
          quantified = false
          i += 1
        end
        flags.empty? ? out : "(?#{flags.join})#{out}"
      end

      # Copies or rewrites the escape at `i`; returns where to go on.
      def escape(source, i, depth, out, refuse)
        e = source[i + 1] or refuse.("a trailing backslash")
        table = depth.zero? ? OUTSIDE : INSIDE
        if e == "0" && source[i + 2]&.match?(/[0-7]/)
          refuse.("an octal escape")
        elsif table.key?(e)
          out << table[e]
        elsif %w[p P].include?(e) && source[i + 2] == "{" && source[i + 3] == "^"
          # Ruby's \p{^Alpha} is Rust's \P{Alpha}.
          close = source.index("}", i) or refuse.("an unclosed \\#{e}{")
          out << "\\" << (e == "p" ? "P" : "p") << "{" << source[i + 4...close] << "}"
          return close + 1
        elsif %w[p P x u].include?(e) && source[i + 2] == "{"
          close = source.index("}", i) or refuse.("an unclosed \\#{e}{")
          out << source[i..close]
          return close + 1
        elsif %w[< >].include?(e) || !e.ascii_only?
          # Literal in Ruby; `\<` and `\>` are word boundaries in Rust, which
          # doesn't allow escaping a non-ASCII character at all.
          out << e
        elsif e.match?(/\s/)
          out << format("\\x{%X}", e.ord)
        elsif KEPT.include?(e) || e.match?(/[^0-9A-Za-z]/)
          out << "\\" << e
        elsif e.match?(/[1-9k]/)
          refuse.("a backreference")
        else
          refuse.("\\#{e}")
        end
        i + 2
      end
    end
  end
end
