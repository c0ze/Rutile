ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

module ActiveSupport
  class TestCase
    parallelize(workers: :number_of_processors)
    fixtures :all
  end
end

module ActionDispatch
  class IntegrationTest
    # Rails' JSON timestamps: UTC, milliseconds.
    TIME = /\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z\z/

    # The header ApplicationController#authenticate reads.
    def auth(user) = { "X-Api-Token" => user.api_token }

    # A timestamp the server just set, in Rails' format. Bounds rather than
    # equality, so it holds when another process serves the request.
    def assert_recent(json)
      assert_match TIME, json
      assert_in_delta Time.current, Time.iso8601(json), 60
    end
  end
end
