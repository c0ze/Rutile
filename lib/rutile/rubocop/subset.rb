module RuboCop
  module Cop
    module Rutile
      # Code whose meaning is only known at run time, or that has no static
      # Rust form: `eval`, `send` with a computed name, `define_method`,
      # `method_missing`, class variables, assigned globals and reopened core
      # classes. The same rules `rutile check` applies (Rutile::Check::Rules),
      # with the same messages.
      #
      # @example
      #   # bad
      #   send("#{field}=", value)
      #
      #   # good
      #   case field
      #   when :title then self.title = value
      #   end
      class Subset < Base
        def on_new_investigation
          source = processed_source
          text = source.raw_source
          ::Rutile::Check::Rules.findings(text, source.file_path.to_s).each do |message, start, finish|
            # Prism counts bytes; the source buffer counts characters.
            range = Parser::Source::Range.new(source.buffer, text.byteslice(0, start).length, text.byteslice(0, finish).length)
            add_offense(range, message: "#{message}.")
          end
        end
      end
    end
  end
end
