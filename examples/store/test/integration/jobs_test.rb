require "test_helper"

# RestockJob runs on Sidekiq, through the Redis that the Ruby and the Rust
# workers share: a job one side enqueues, the other runs.
class JobsTest < ActionDispatch::IntegrationTest
  setup { Sidekiq.redis { _1.call("DEL", "queue:default") } }

  test "a job the server enqueues, Sidekiq's Ruby worker runs" do
    post restock_later_product_path(products(:mug)), params: { amount: 4 }, as: :json
    assert_response :accepted
    assert_equal({ "queued" => true }, response.parsed_body)
    payload = JSON.parse(Sidekiq.redis { _1.call("RPOP", "queue:default") })
    assert_equal ["Sidekiq::ActiveJob::Wrapper", "RestockJob", "default", true], payload.values_at("class", "wrapped", "queue", "retry")
    assert_equal [{ "_aj_globalid" => products(:mug).to_global_id.to_s }, 4], payload["args"].first["arguments"]
    # What Sidekiq's processor calls with a job it takes.
    Sidekiq::ActiveJob::Wrapper.new.perform(payload["args"].first)
    assert_equal 4, products(:mug).reload.stock
  end

  test "a job Rails enqueues, the server's worker runs" do
    RestockJob.perform_later(products(:mug), 2)
    work_once
    assert_equal 2, products(:mug).reload.stock
    assert_equal 0, Sidekiq.redis { _1.call("LLEN", "queue:default") }
  end

  private

  # The worker of the build under test when verify names one; Sidekiq's
  # own processing otherwise.
  def work_once
    if (binary = ENV["RUTILE_BINARY"])
      env = { "DATABASE_URL" => ENV.fetch("RUTILE_DATABASE_URL"), "REDIS_URL" => ENV.fetch("REDIS_URL") }
      assert system(env, binary, "work", "--once"), "#{binary} work --once failed"
    else
      payload = JSON.parse(Sidekiq.redis { _1.call("RPOP", "queue:default") })
      Sidekiq::ActiveJob::Wrapper.new.perform(payload["args"].first)
    end
  end
end
