module Rutile
  module Check
    # The app's own gems, by what compiling means for them. Gems only in
    # development or test never ship.
    module Gems
      # They never reach compiled code: the framework, the database driver,
      # servers, deployment and asset tooling.
      NEUTRAL = %w[rails pg puma bootsnap tzinfo-data thruster kamal propshaft].freeze
      # They change Rails at runtime, so nothing of theirs can be compiled.
      SIDECAR = %w[activeadmin rails_admin paper_trail ransack devise].freeze

      module_function

      def check(manifest, diagnostics)
        gems = manifest["gems"]
        unless gems
          return diagnostics.note("Gemfile: the manifest has no gem list (manifest_version #{manifest["manifest_version"]}); " \
                                  "introspect again")
        end

        gems.each do |gem|
          name = gem["name"]
          next if (gem["groups"] - %w[development test]).empty? || NEUTRAL.include?(name)

          if SIDECAR.include?(name)
            diagnostics.problem("Gemfile: #{name} changes Rails at runtime and can't be compiled; " \
                                "use a Rails sidecar for what needs it, or a rewrite")
          else
            diagnostics.note("Gemfile: #{name} isn't known to Rutile; rutile build refuses any use of it the translator can't compile")
          end
        end
      end
    end
  end
end
