require "test_helper"

class TasksApiTest < ActionDispatch::IntegrationTest
  test "index orders by due date and flags overdue tasks" do
    get project_tasks_path(projects(:apollo)), headers: auth(users(:alice))
    assert_response :ok
    assert_equal [["Ship", false], ["Launch", true], ["Review", false]],
                 response.parsed_body.map { [_1["title"], _1["overdue"]] }
  end

  test "index filters by status and searches titles" do
    get project_tasks_path(projects(:apollo), status: "todo"), headers: auth(users(:alice))
    assert_equal %w[Launch], response.parsed_body.map { _1["title"] }
    get project_tasks_path(projects(:apollo), q: "REV"), headers: auth(users(:alice))
    assert_equal %w[Review], response.parsed_body.map { _1["title"] }
  end

  test "create uses the defaults" do
    post project_tasks_path(projects(:apollo)), params: { task: { title: "Land" } }, headers: auth(users(:alice)), as: :json
    assert_response :created
    assert_equal %w[todo normal], response.parsed_body.values_at("status", "priority")
  end

  test "a zero estimate or an assignee from outside the project is a 422" do
    post project_tasks_path(projects(:apollo)), params: { task: { title: "Land", estimate: 0 } },
                                                headers: auth(users(:alice)), as: :json
    assert_response :unprocessable_content
    assert_equal({ "estimate" => ["must be greater than 0"] }, response.parsed_body)
    carol = User.create!(name: "Carol", email: "carol@example.com")
    post project_tasks_path(projects(:apollo)), params: { task: { title: "Land", assignee_id: carol.id } },
                                                headers: auth(users(:alice)), as: :json
    assert_response :unprocessable_content
    assert_equal({ "assignee" => ["must be a member of the project"] }, response.parsed_body)
  end

  test "complete stamps the time and reopening clears it" do
    task = tasks(:review)
    patch complete_task_path(task), headers: auth(users(:alice))
    assert_response :ok
    assert_equal "done", response.parsed_body["status"]
    assert response.parsed_body["completed_at"]
    patch task_path(task), params: { task: { status: "doing" } }, headers: auth(users(:alice)), as: :json
    assert_nil response.parsed_body["completed_at"]
  end

  test "someone else's task is a 404, and destroy is a 204" do
    get task_path(tasks(:secret)), headers: auth(users(:alice))
    assert_response :not_found
    delete task_path(tasks(:launch)), headers: auth(users(:alice))
    assert_response :no_content
  end
end
