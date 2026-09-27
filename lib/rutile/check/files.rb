module Rutile
  module Check
    # App files outside what Rutile compiles. Unused, they're harmless; used,
    # the build refuses the reference, so they're notes rather than problems.
    module Files
      COMPILED = %r{\Aapp/(models|controllers|jobs)/[^/]+\.rb\z}

      module_function

      def check(root, diagnostics)
        Dir.glob("app/**/*.rb", base: root).sort.reject { _1.match?(COMPILED) }.each do |path|
          diagnostics.note("#{path}: not compiled; Rutile compiles app/models, app/controllers, app/jobs, app/views and config/routes.rb")
        end
      end
    end
  end
end
