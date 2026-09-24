require "test_helper"

class CommentsApiTest < ActionDispatch::IntegrationTest
  test "index lists a post's comments oldest first" do
    get post_comments_path(posts(:published_old)), as: :json
    assert_response :ok
    assert_equal [comments(:first).id], response.parsed_body.map { _1["id"] }
  end

  test "create adds a comment and bumps the counter" do
    target = posts(:published_new)
    assert_difference -> { target.reload.comments_count }, 1 do
      post post_comments_path(target), params: { user_id: users(:alice).id, body: "Agreed" }, as: :json
    end
    assert_response :created
  end

  test "comments on a missing post are a JSON 404" do
    get post_comments_path(post_id: 0), as: :json
    assert_response :not_found
  end
end
