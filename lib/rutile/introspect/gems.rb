module Rutile
  module Introspect
    # The Gemfile's direct dependencies and their groups, so `rutile check`
    # can tell shipped gems from development tools.
    module Gems
      module_function

      def extract
        Bundler.definition.dependencies.map { { "name" => _1.name, "groups" => _1.groups.map(&:to_s).sort } }
               .sort_by { _1["name"] }
      end
    end
  end
end
