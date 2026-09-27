module Rutile
  module Introspect
    # The manifest's format. It goes up whenever a field is added, removed
    # or changes meaning; the build reads only its own version.
    MANIFEST_VERSION = 4
  end
end
