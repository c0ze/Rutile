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

      def initialize(base_url, routes = nil)
        @uri = URI(base_url)
        @routes = routes
      end

      def call(env)
        request = Rack::Request.new(env)
        body = request.body&.read.to_s
        outgoing = Net::HTTPGenericRequest.new(request.request_method, !body.empty?, request.request_method != "HEAD", request.fullpath)
        FORWARDED.each { |key, header| outgoing[header] = env[key] if env[key] }
        outgoing.body = body unless body.empty?
        response = Net::HTTP.start(@uri.host, @uri.port) { |http| http.request(outgoing) }
        headers = {}
        headers["content-type"] = response["content-type"] if response["content-type"]
        [response.code.to_i, headers, [response.body.to_s]]
      end

      # Points integration tests at `base_url`. Fixtures are committed rather
      # than wrapped in a per-test transaction, because the other server reads
      # the database through its own connections; Rails then reloads them
      # before every test.
      def self.install(base_url)
        ActionDispatch::IntegrationTest.app = new(base_url, Rails.application.routes)
        ActiveSupport::TestCase.use_transactional_tests = false
      end
    end
  end
end
