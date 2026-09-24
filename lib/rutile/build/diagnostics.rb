module Rutile
  module Build
    # A failure already reported: whatever depended on it is skipped quietly.
    class Skipped < Unsupported; end

    # Collects every finding instead of stopping at the first, for `rutile
    # check`. Findings are `path:line: message` or `path: message` strings.
    class Diagnostics
      def initialize
        @problems = []
        @notes = []
      end

      # Runs the block; an Unsupported becomes a problem and `fallback` its
      # result, so the caller moves on to the next unit.
      def attempt(fallback = nil)
        yield
      rescue Skipped
        fallback
      rescue Unsupported => e
        problem(e.message)
        fallback
      end

      def problem(message) = (@problems << message unless @problems.include?(message))
      def note(message) = (@notes << message unless @notes.include?(message))

      def problems = sorted(@problems)
      def notes = sorted(@notes)
      def empty? = @problems.empty? && @notes.empty?

      private

      def sorted(messages)
        messages.sort_by do |message|
          path, line = message.match(/\A([^:]+)(?::(\d+))?:/)&.captures
          [path.to_s, line.to_i, message]
        end
      end
    end
  end
end
