require "test_helper"

class PostsApiTest < ActionDispatch::IntegrationTest
  test "index lists published posts newest first with their author" do
    get posts_path, as: :json
    assert_response :ok

    body = response.parsed_body
    assert_equal [posts(:published_new).id, posts(:published_old).id], body.map { _1["id"] }
    assert_equal({ "id" => users(:bob).id, "name" => "Bob" }, body.first["user"])
  end

  test "show returns the post" do
    get post_path(posts(:draft)), as: :json
    assert_response :ok
    assert_equal "Work in progress", response.parsed_body["title"]
  end

  test "show of a missing post is a JSON 404" do
    get post_path(id: 0), as: :json
    assert_response :not_found
    assert_equal({ "error" => "not found" }, response.parsed_body)
  end

  test "create accepts unwrapped JSON params" do
    assert_difference -> { Post.count }, 1 do
      post posts_path, params: { user_id: users(:alice).id, title: "New", body: "Hello", status: "published" }, as: :json
    end
    assert_response :created
    assert_not_nil response.parsed_body["published_at"]
  end

  test "create with a blank title is a 422 with errors" do
    post posts_path, params: { user_id: users(:alice).id, title: "" }, as: :json
    assert_response :unprocessable_content
    assert_includes response.parsed_body["title"], "can't be blank"
  end

  test "create with an unknown status is a 422, not a 500" do
    post posts_path, params: { user_id: users(:alice).id, title: "Hi", status: "archived" }, as: :json
    assert_response :unprocessable_content
    assert_includes response.parsed_body["status"], "is not included in the list"
  end

  test "update changes the title" do
    patch post_path(posts(:draft)), params: { title: "Done" }, as: :json
    assert_response :ok
    assert_equal "Done", posts(:draft).reload.title
  end

  test "destroy removes the post and its comments" do
    assert_difference -> { Comment.count }, -1 do
      delete post_path(posts(:published_old)), as: :json
    end
    assert_response :no_content
  end
end
