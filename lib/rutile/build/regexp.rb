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
        # Case-insensitivity and extended mode, per open group: `(?i)` sets
        # a flag to the end of its group, `(?i:...)` inside its own.
        modes = [{ "i" => flags.include?("i"), "x" => flags.include?("x") }]
        out = +""
        depth = 0
        quantified = false
        i = 0
        while i < source.size
          c = source[i]
          if c == "\\"
            i = escape(source, i, depth, out, refuse, modes.last["i"])
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
          elsif c == "#" && modes.last["x"]
            # A comment to the end of the line, which Rust's (?x) reads the
            # same; nothing in it is syntax.
            stop = source.index("\n", i) || source.size
            out << source[i...stop]
            i = stop
            next
          else
            case c
            when "[" then depth += 1
            when "^", "$" then flags << "m" unless flags.include?("m")
            when ")" then modes.pop if modes.size > 1
            when "("
              group = source[i + 1..][/\A\?([imx-]+)([:)])/]
              if group
                on, off = group[1..-2].split("-", 2)
                mode = modes.last.to_h { |flag, set| [flag, off.to_s.include?(flag) ? false : on.include?(flag) || set] }
                group.end_with?(":") ? modes.push(mode) : modes[-1] = mode
                out << group.tr("m", "s").prepend("(")
                i += group.size + 1
                next
              end
              modes.push(modes.last)
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
          if c == "[" && (lead = source[i + 1..][/\A\^?\]/])
            # A ] first in a class is literal in both engines; escaped, no
            # reader takes it for the end.
            out << c << lead.sub("]", "\\]")
            i += 1 + lead.size
            quantified = false
            next
          end
          out << c
          quantified = false
          i += 1
        end
        flags.empty? ? out : "(?#{flags.join})#{out}"
      end

      # Copies or rewrites the escape at `i`; returns where to go on.
      def escape(source, i, depth, out, refuse, folding)
        e = source[i + 1] or refuse.("a trailing backslash")
        table = depth.zero? ? OUTSIDE : INSIDE
        if e == "0" && source[i + 2]&.match?(/[0-7]/)
          refuse.("an octal escape")
        elsif folding && %w[w W].include?(e)
          # Rust folds the Kelvin sign and the long s into [a-zA-Z] under
          # (?i); Ruby's \w and \W don't. A class can't turn folding off
          # for part of itself.
          refuse.("\\#{e} in a bracket under /i") unless depth.zero?
          out << "(?-i:#{table[e]})"
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
