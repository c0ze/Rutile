ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

module ActiveSupport
  class TestCase
    parallelize(workers: :number_of_processors)
    fixtures :all
  end
end

# `rake example:verify` runs these tests against the Rust build through a proxy.
if (target = ENV["RUTILE_TARGET"])
  require_relative "../../../lib/rutile/verify/target"
  Rutile::Verify::Target.install(target)
end
