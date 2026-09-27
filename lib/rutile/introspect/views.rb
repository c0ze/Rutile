module Rutile
  module Introspect
    # The app's templates under app/views, each with the Ruby that Rails'
    # own handler compiles it to. That Ruby carries Rails' trimming and
    # escaping choices, so the build translates it rather than the ERB.
    module Views
      module_function

      def extract(app)
        return [] unless defined?(ActionView::Template)

        root = app.root.join("app/views")
        Dir.glob("**/*", base: root).sort.filter_map do |file|
          path = root.join(file)
          describe("app/views/#{file}", file, path.read) if path.file?
        end
      end

      # Per full-stack controller, the view helpers the app defines, as
      # Rails mixes them into that controller's views, however they're
      # defined (a def, attr_reader, under a condition, through send): a
      # method whose code is the app's, or that an app module owns (an alias
      # of Action View's keeps its code's location). A module nested in a
      # helper but not included isn't among them.
      def helpers(app)
        return {} unless defined?(ActionController::Base)

        root = "#{app.root}/"
        mine = ->(file) { file&.start_with?(root) && Gem.path.none? { file.start_with?("#{_1}/") } }
        ActionController::Base.descendants.select { Source.app_defined?(_1) }.sort_by(&:name).to_h do |controller|
          helpers = controller._helpers
          names = (helpers.instance_methods + helpers.private_instance_methods).select do |name|
            method = helpers.instance_method(name)
            mine.(method.source_location&.first) || Source.app_defined?(method.owner)
          end
          [controller.name, names.map(&:to_s).sort]
        end
      end

      # `storefront/index.html.erb`: the name `render` looks up, its format
      # and handler, and the compiled source for an ERB template.
      def describe(path, file, source)
        name, format, handler = parse(file)
        {
          "path" => path,
          "name" => name,
          "format" => format,
          "handler" => handler,
          "partial" => File.basename(name).start_with?("_"),
          "src" => handler == "erb" ? compile(path, name, format, source) : nil
        }
      end

      def parse(file)
        parts = file.split("/")
        base, *extensions = parts.last.split(".")
        handler = extensions.pop
        [[*parts[0...-1], base].join("/"), extensions.first, handler]
      end

      def compile(path, name, format, source)
        handler = ActionView::Template.handler_for_extension("erb")
        template = ActionView::Template.new(source, path, handler, locals: [], format: format&.to_sym, virtual_path: name)
        handler.call(template, source)
      end
    end
  end
end
