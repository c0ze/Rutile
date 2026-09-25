require_relative "../build_helper"
require_relative "../tracker_helper"

class QueriesTest < Minitest::Test
  include BuildHelper
  include TrackerHelper

  def controller(name, app = tracker) = [Rutile::Build::ControllerFile.new(app, name).to_rust, app.diagnostics.problems]

  def translate(ruby, model:, app: tracker)
    translator = Rutile::Build::Translator.new(app, "snippet.rb", Rutile::Build::Uses.new, env: :model, model:,
                                                                                           self_var: Rutile::Build::Names.snake(model))
    translator.body(Prism.parse(ruby).value.statements, :unit).first.join("\n")
  end

  def refused(message, &)
    error = assert_raises(Rutile::Build::Unsupported, &)
    assert_includes error.message, message
  end

  # projects#index: current_user.projects.active.order(:name).limit(PER_PAGE).offset((page - 1) * PER_PAGE)
  def test_pagination_with_a_constant_and_arithmetic
    rust, problems = controller("ProjectsController")
    refute problems.any? { _1.start_with?("app/controllers/projects_controller.rb:7:") }, problems.join("\n")
    assert_rust_includes rust, "// app/controllers/projects_controller.rb:2\nconst PER_PAGE: i64 = 20;"
    assert_rust_includes rust, '.active().order_asc("name").limit(PER_PAGE);'
    assert_rust_includes rust, ".offset((self.page(req)? - 1) * PER_PAGE);"
    assert_rust_includes rust, <<~RUST
      fn page(&mut self, req: &mut Request) -> Result<i64> {
          Ok(i64::max(req.params.fetch("page", 1).to_i()?, 1))
      }
    RUST
  end

  # set_task: Task.joins(project: :memberships).where(memberships: { user_id: current_user.id }).find(params[:id])
  def test_joins_and_a_where_on_the_joined_table
    rust, problems = controller("TasksController")
    refute problems.any? { _1.start_with?("app/controllers/tasks_controller.rb:43:") }, problems.join("\n")
    # The relation has a `?` in it, so it's read before params[:id], as Ruby does.
    assert_rust_includes rust, "let tasks = Task::all().joins(&Task::PROJECT).joins(&Project::MEMBERSHIPS)" \
                               '.where_on::<Membership>("user_id", req.ctx[self.current_user.ok_or(Error::Nil { what: "id" })?].id);'
    assert_rust_includes rust, 'self.task = Some(tasks.find(&mut req.ctx, req.params.value("id"))?);'
  end

  # has_many :through joins its join table, so a where can name it.
  def test_where_on_the_through_join_table
    assert_rust_includes translate('found = projects.where(memberships: { role: "admin" })', model: "User"),
                         'let found = User::PROJECTS.of(ctx, user).where_on::<Membership>("role", "admin");'
  end

  def test_joins_that_would_break_are_refused
    refused("joining projects twice") { translate("found = Task.joins(:project, :project)", model: "Task") }
    refused("joining tasks twice") { translate("found = Task.joins(project: :tasks)", model: "Task") }
    refused("joins(:members), a has_many through memberships") { translate("found = Project.joins(:members)", model: "Project") }
    refused("joins(:nothing), which Task doesn't have") { translate("found = Task.joins(:nothing)", model: "Task") }
    refused("a list that isn't symbols") { translate("found = Task.joins(project: { memberships: :user })", model: "Task") }
    refused("where on users, which the relation doesn't join") do
      translate("found = Task.joins(:project).where(users: { id: 1 })", model: "Task")
    end
    refused("limit with int or nil") { translate("found = Task.limit(estimate)", model: "Task") }
  end
end
