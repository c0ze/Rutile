require "net/http"

module Rutile
  module Verify
    # A Rack app that forwards each request of a Rails integration test to
    # another server, so the app's own tests exercise a compiled build.
    class Target
      FORWARDED = { "CONTENT_TYPE" => "Content-Type", "HTTP_ACCEPT" => "Accept" }.freeze

      # The app's route set: integration tests only get URL helpers such as
      # `posts_path` from an app that answers `routes`.
      attr_reader :routes

      # `after_request` runs once each response is back.
      def initialize(base_url, routes = nil, &after_request)
        @uri = URI(base_url)
        @routes = routes
        @after_request = after_request
      end

      def call(env)
        request = Rack::Request.new(env)
        body = request.body&.read.to_s
        outgoing = Net::HTTPGenericRequest.new(request.request_method, !body.empty?, request.request_method != "HEAD", request.fullpath)
        FORWARDED.each { |key, header| outgoing[header] = env[key] if env[key] }
        outgoing.body = body unless body.empty?
        response = Net::HTTP.start(@uri.host, @uri.port) { |http| http.request(outgoing) }
        @after_request&.call
        headers = {}
        headers["content-type"] = response["content-type"] if response["content-type"]
        [response.code.to_i, headers, [response.body.to_s]]
      end

      # Points integration tests at `base_url`. Fixtures are committed rather
      # than wrapped in a per-test transaction, because the other server reads
      # the database through its own connections; Rails then reloads them
      # before every test. Each test runs inside the executor with the query
      # cache on, and writes made by another process can't clear it, so every
      # forwarded request clears it the way an in-process write would.
      def self.install(base_url)
        target = new(base_url, Rails.application.routes) { ActiveRecord::Base.clear_query_caches_for_current_thread }
        ActionDispatch::IntegrationTest.app = target
        ActiveSupport::TestCase.use_transactional_tests = false
      end
    end
  end
end
