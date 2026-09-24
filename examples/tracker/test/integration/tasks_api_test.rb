require "test_helper"

class TasksApiTest < ActionDispatch::IntegrationTest
  test "index orders by due date and flags overdue tasks" do
    get project_tasks_path(projects(:apollo)), headers: auth(users(:alice))
    assert_response :ok
    assert_equal [["Ship", false], ["Launch", true], ["Review", false]],
                 response.parsed_body.map { [_1["title"], _1["overdue"]] }
    assert_equal [5.days.ago.to_date.iso8601, 3.days.ago.to_date.iso8601, nil], response.parsed_body.map { _1["due_on"] }
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
    assert_recent response.parsed_body["completed_at"]
    patch task_path(task), params: { task: { status: "doing" } }, headers: auth(users(:alice)), as: :json
    assert_response :ok
    assert_equal "doing", response.parsed_body["status"]
    assert_nil response.parsed_body["completed_at"]
    assert_nil task.reload.completed_at
  end

  test "someone else's task is a 404, and destroy is a 204" do
    get task_path(tasks(:secret)), headers: auth(users(:alice))
    assert_response :not_found
    assert_equal({ "error" => "not found" }, response.parsed_body)
    get task_path(0), headers: auth(users(:alice))
    assert_response :not_found
    delete task_path(tasks(:launch)), headers: auth(users(:alice))
    assert_response :no_content
  end

  test "a task renders its columns" do
    get task_path(tasks(:launch)), headers: auth(users(:alice))
    assert_response :ok
    body = response.parsed_body
    assert_equal %w[assignee_id completed_at created_at due_on estimate id notes priority project_id status title updated_at],
                 body.keys.sort
    assert_equal [3.days.ago.to_date.iso8601, users(:bob).id, "normal"], body.values_at("due_on", "assignee_id", "priority")
  end

  test "tasks due the same day keep their id order" do
    due = 2.days.from_now.to_date
    first = projects(:apollo).tasks.create!(title: "B", due_on: due)
    second = projects(:apollo).tasks.create!(title: "A", due_on: due)
    get project_tasks_path(projects(:apollo)), headers: auth(users(:alice))
    ids = response.parsed_body.map { _1["id"] }
    assert_operator ids.index(first.id), :<, ids.index(second.id)
  end

  test "an invalid update is a 422 and changes nothing" do
    patch task_path(tasks(:launch)), params: { task: { estimate: -1 } }, headers: auth(users(:alice)), as: :json
    assert_response :unprocessable_content
    assert_equal({ "estimate" => ["must be greater than 0"] }, response.parsed_body)
    assert_nil tasks(:launch).reload.estimate
  end
end
