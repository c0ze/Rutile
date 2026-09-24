ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Add more helper methods to be used by all tests here...
  end
end

# `rake example:verify` runs these tests against the Rust build through a proxy.
if (target = ENV["RUTILE_TARGET"])
  require_relative "../../../lib/rutile/verify/target"
  Rutile::Verify::Target.install(target)
end
