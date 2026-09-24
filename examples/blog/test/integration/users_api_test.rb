require "test_helper"

class UsersApiTest < ActionDispatch::IntegrationTest
  test "create with nested params" do
    post users_path, params: { user: { name: "Carol", email: "carol@example.com" } }, as: :json
    assert_response :created
    assert_equal "carol@example.com", response.parsed_body["email"]
  end

  test "create with a taken email is a 422" do
    post users_path, params: { user: { name: "Alice", email: "ALICE@example.com" } }, as: :json
    assert_response :unprocessable_content
    assert_includes response.parsed_body["email"], "has already been taken"
  end

  test "show returns the user" do
    get user_path(users(:bob)), as: :json
    assert_response :ok
    assert_equal "Bob", response.parsed_body["name"]
  end

  test "lookup finds a user by email" do
    get lookup_users_path(email: " BOB@example.com "), as: :json
    assert_response :ok
    assert_equal users(:bob).id, response.parsed_body["id"]
  end

  test "lookup of an unknown email is a JSON 404" do
    get lookup_users_path(email: "nobody@example.com"), as: :json
    assert_response :not_found
  end

  test "lookup without an email fails its route constraint and falls through to show" do
    get lookup_users_path, as: :json
    assert_response :not_found
    assert_equal({ "error" => "not found" }, response.parsed_body)
    # Which action ran is only visible inside Rails.
    assert_equal "show", controller.action_name unless ENV["RUTILE_TARGET"]
  end
end
