require "net/http"

module Rutile
  module Verify
    # A Rack app that forwards each request of a Rails integration test to
    # another server, so the app's own tests exercise a compiled build.
    class Target
      # Request headers that describe the connection, which Net::HTTP writes
      # for its own; Rack's HTTP_VERSION is the protocol, not a header.
      HOP = %w[HTTP_HOST HTTP_CONNECTION HTTP_CONTENT_LENGTH HTTP_TRANSFER_ENCODING HTTP_KEEP_ALIVE HTTP_VERSION].freeze
      # Headers Net::HTTP fills in by itself. Given its own Accept-Encoding,
      # it would also inflate the response before the test saw it.
      DEFAULTED = %w[accept accept-encoding user-agent].freeze
      # Response headers about the connection, not the response; the rest
      # (Location, Set-Cookie, ...) go back to the test.
      CONNECTION = %w[connection keep-alive transfer-encoding content-length].freeze

      # The app's route set: integration tests only get URL helpers such as
      # `posts_path` from an app that answers `routes`.
      attr_reader :routes

      # How many requests went to the other server.
      attr_reader :forwarded

      # `after_request` runs once each response is back.
      def initialize(base_url, routes = nil, &after_request)
        @uri = URI(base_url)
        @routes = routes
        @after_request = after_request
        @forwarded = 0
      end

      def call(env)
        request = Rack::Request.new(env)
        body = request.body&.read.to_s
        # Naming accept-encoding up front is what stops Net::HTTP inflating.
        outgoing = Net::HTTPGenericRequest.new(request.request_method, !body.empty?, request.request_method != "HEAD",
                                               request.fullpath, "accept-encoding" => "identity")
        DEFAULTED.each { outgoing.delete(_1) }
        headers(env).each { |header, value| outgoing[header] = value }
        outgoing.body = body unless body.empty?
        response = Net::HTTP.start(@uri.host, @uri.port) { |http| http.request(outgoing) }
        @forwarded += 1
        @after_request&.call
        headers = response.each_header.to_h.except(*CONNECTION, "set-cookie")
        # Each cookie is its own header; Rack 3 takes them as an array.
        cookies = response.get_fields("set-cookie")
        headers["set-cookie"] = cookies if cookies
        # Net::HTTP reads bytes; a test compares text in the charset sent.
        body = response.body.to_s
        body = body.dup.force_encoding(Encoding::UTF_8) if response["content-type"].to_s.downcase.include?("charset=utf-8")
        [response.code.to_i, headers, [body]]
      end

      # What the test sent: Content-Type and every HTTP_* header but the
      # connection's own. Rack spells `X-Api-Token` as HTTP_X_API_TOKEN.
      def headers(env)
        sent = env.select { |key, value| key.start_with?("HTTP_") && !HOP.include?(key) && value }
        sent = sent.to_h { |key, value| [key.delete_prefix("HTTP_").split("_").map(&:capitalize).join("-"), value.to_s] }
        env["CONTENT_TYPE"] ? sent.merge("Content-Type" => env["CONTENT_TYPE"]) : sent
      end

      # Without a transaction to roll back, Rails reloads the fixtures before
      # each test, but a table no fixture file fills would keep what earlier
      # tests wrote. So every table is emptied first, and the fixtures load
      # into empty tables: nothing needs to know which tables they fill.
      module EmptyTables
        def setup_fixtures(...)
          unless run_in_transaction?
            pool = ActiveRecord::Base.connection_pool
            internal = [pool.schema_migration.table_name, pool.internal_metadata.table_name]
            Target.empty_tables(ActiveRecord::Base.connection, internal:)
          end
          super
        end
      end

      def self.empty_tables(connection, internal:)
        tables = connection.tables - internal
        return if tables.empty?

        # Nested as Rails nests them to load fixtures, so a failed delete
        # rolls back the disabled triggers too.
        connection.transaction(requires_new: true) do
          connection.disable_referential_integrity do
            tables.each { connection.delete("DELETE FROM #{connection.quote_table_name(_1)}") }
          end
        end
      end

      # Points integration tests at `base_url`. Fixtures are committed rather
      # than wrapped in a per-test transaction, because the other server reads
      # the database through its own connections; Rails then reloads them
      # before every test, into tables EmptyTables has emptied. Each test runs
      # inside the executor with the query cache on, and writes made by
      # another process can't clear it, so every forwarded request clears it
      # the way an in-process write would.
      def self.install(base_url)
        target = new(base_url, Rails.application.routes) { ActiveRecord::Base.clear_query_caches_for_current_thread }
        ActionDispatch::IntegrationTest.app = target
        ActiveSupport::TestCase.use_transactional_tests = false
        ActiveSupport::TestCase.prepend(EmptyTables)
        # A green run that never reached the other server tested Rails.
        Minitest.after_run do
          next unless target.forwarded.zero?

          warn "rutile verify: no request reached #{base_url}; the tests ran against Rails"
          exit false
        end
        target
      end
    end
  end
end
