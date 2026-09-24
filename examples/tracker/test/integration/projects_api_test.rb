require "test_helper"

class ProjectsApiTest < ActionDispatch::IntegrationTest
  test "index lists my active projects by name, a page at a time" do
    get projects_path, headers: auth(users(:bob))
    assert_response :ok
    assert_equal %w[Apollo Hermes], response.parsed_body.map { _1["name"] }
    get projects_path, headers: auth(users(:alice))
    assert_equal %w[Apollo], response.parsed_body.map { _1["name"] }
    get projects_path(page: 2), headers: auth(users(:alice))
    assert_equal [], response.parsed_body
  end

  test "create makes the creator an admin" do
    post projects_path, params: { project: { name: "Artemis" } }, headers: auth(users(:alice)), as: :json
    assert_response :created
    project = Project.find(response.parsed_body["id"])
    assert_equal users(:alice), project.owner
    assert Membership.find_by(user: users(:alice), project:).admin?
  end

  test "a blank or taken name is a 422" do
    post projects_path, params: { project: { name: "" } }, headers: auth(users(:alice)), as: :json
    assert_response :unprocessable_content
    assert_equal({ "name" => ["can't be blank"] }, response.parsed_body)
    post projects_path, params: { project: { name: "Apollo" } }, headers: auth(users(:alice)), as: :json
    assert_response :unprocessable_content
    assert_equal({ "name" => ["has already been taken"] }, response.parsed_body)
  end

  test "show includes the tasks' ids, titles and statuses" do
    get project_path(projects(:apollo)), headers: auth(users(:bob))
    assert_response :ok
    tasks = response.parsed_body["tasks"]
    assert_equal %w[id status title], tasks.first.keys.sort
    assert_equal %w[Launch Review Ship], tasks.map { _1["title"] }.sort
  end

  test "someone else's project is a 404" do
    get project_path(projects(:hermes)), headers: auth(users(:alice))
    assert_response :not_found
    assert_equal({ "error" => "not found" }, response.parsed_body)
  end

  test "update, archive and destroy" do
    apollo = projects(:apollo)
    patch project_path(apollo), params: { project: { name: "Apollo 11" } }, headers: auth(users(:alice)), as: :json
    assert_equal "Apollo 11", response.parsed_body["name"]
    post archive_project_path(apollo), headers: auth(users(:alice))
    assert_response :ok
    assert response.parsed_body["archived_at"]
    get projects_path, headers: auth(users(:alice))
    assert_equal [], response.parsed_body
    assert_difference -> { Task.count }, -3 do
      delete project_path(apollo), headers: auth(users(:alice))
    end
    assert_response :no_content
  end
end
