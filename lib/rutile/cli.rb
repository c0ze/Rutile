require "optparse"

module Rutile
  # Parses arguments and dispatches. Each command's work lives in its own module.
  class CLI
    USAGE = <<~TEXT
      usage: rutile --version
             rutile introspect [APP_DIR] [--env ENV] [--out FILE]
             rutile check [APP_DIR] [--manifest FILE] [--env ENV]
             rutile build [APP_DIR] --out DIR --runtime PATH [--name NAME] [--manifest FILE] [--env ENV]
             rutile verify [APP_DIR] --crate DIR [--test PATH]...
             rutile package --crate DIR --runtime PATH --out DIR [--image TAG]
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
      when "check"
        check
      when "build"
        build
      when "verify"
        verify
      when "package"
        package
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

    def check
      options = { env: "development" }
      OptionParser.new do |parser|
        %w[manifest env].each { |key| parser.on("--#{key} VALUE") { options[key.to_sym] = _1 } }
      end.parse!(@argv)
      app_dir = File.expand_path(@argv.shift || ".")
      diagnostics = Check.run(app_dir:, env: options[:env], manifest: options[:manifest] && File.expand_path(options[:manifest]))
      @out.puts Check.report(diagnostics)
      diagnostics.problems.empty? ? 0 : 1
    rescue OptionParser::ParseError
      usage
    rescue Build::Error, Introspect::Error => e
      @err.puts "rutile check: #{e.message}"
      1
    end

    def build
      options = { env: "development", runtime: ENV.fetch("RUSTONRAILS_DIR", nil) }
      OptionParser.new do |parser|
        %w[out runtime name manifest env].each { |key| parser.on("--#{key} VALUE") { options[key.to_sym] = _1 } }
      end.parse!(@argv)
      return usage unless options[:out] && options[:runtime]

      app_dir = File.expand_path(@argv.shift || ".")
      fallbacks = Build.run(app_dir:, out: File.expand_path(options[:out]), runtime: File.expand_path(options[:runtime]),
                            name: options[:name] || File.basename(app_dir), env: options[:env],
                            manifest: options[:manifest] && File.expand_path(options[:manifest]))
      @out.puts fallbacks
      @out.puts "wrote #{options[:out]}#{" (#{fallbacks.size} Value fallback#{"s" unless fallbacks.size == 1})" unless fallbacks.empty?}"
      0
    rescue OptionParser::ParseError
      usage
    rescue Build::Error, Introspect::Error => e
      @err.puts "rutile build: #{e.message}"
      1
    end

    # The app's integration tests (or --test paths) against the crate.
    def verify
      options = { tests: [] }
      OptionParser.new do |parser|
        parser.on("--crate DIR") { options[:crate] = _1 }
        parser.on("--test PATH") { options[:tests] << _1 }
      end.parse!(@argv)
      return usage unless options[:crate]

      tests = options[:tests].empty? ? ["test/integration"] : options[:tests]
      passed = Verify.run(app_dir: File.expand_path(@argv.shift || "."), crate: File.expand_path(options[:crate]), tests:, out: @out)
      passed ? 0 : 1
    rescue OptionParser::ParseError
      usage
    rescue Verify::Error, Verify::Servers::Error => e
      @err.puts "rutile verify: #{e.message}"
      1
    end

    def package
      options = { runtime: ENV.fetch("RUSTONRAILS_DIR", nil) }
      OptionParser.new do |parser|
        %w[crate runtime out image].each { |key| parser.on("--#{key} VALUE") { options[key.to_sym] = _1 } }
      end.parse!(@argv)
      return usage unless options[:crate] && options[:runtime] && options[:out]

      binary = Package.run(crate: File.expand_path(options[:crate]), runtime: File.expand_path(options[:runtime]),
                           out: options[:out], image: options[:image], log: @out)
      @out.puts "binary: #{binary}"
      @out.puts "image: #{options[:image]}" if options[:image]
      0
    rescue OptionParser::ParseError
      usage
    rescue Package::Error => e
      @err.puts "rutile package: #{e.message}"
      1
    end

    def usage
      @err.puts USAGE
      1
    end
  end
end
