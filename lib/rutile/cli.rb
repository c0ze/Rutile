require "optparse"

module Rutile
  # Parses arguments and dispatches. Each command's work lives in its own module.
  class CLI
    USAGE = <<~TEXT
      usage: rutile --version
             rutile introspect [APP_DIR] [--env ENV] [--out FILE]
    TEXT

    def initialize(argv, out: $stdout, err: $stderr)
      @argv = argv.dup
      @out = out
      @err = err
    end

    def run
      case @argv.shift
      when "--version", "-v"
        @out.puts "rutile #{VERSION}"
        0
      when "introspect"
        introspect
      else
        usage
      end
    end

    private

    def introspect
      options = { env: "development" }
      OptionParser.new do |parser|
        parser.on("--env ENV") { options[:env] = _1 }
        parser.on("--out FILE") { options[:out] = _1 }
      end.parse!(@argv)
      app_dir = File.expand_path(@argv.shift || ".")
      out = File.expand_path(options[:out] || File.join(app_dir, "tmp/rutile/manifest.json"))
      Introspect.run(app_dir: app_dir, env: options[:env], out: out)
      @out.puts "wrote #{out}"
      0
    rescue OptionParser::ParseError
      usage
    rescue Introspect::Error => e
      @err.puts "rutile introspect: #{e.message}"
      1
    end

    def usage
      @err.puts USAGE
      1
    end
  end
end
