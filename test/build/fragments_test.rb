require_relative "../build_helper"
require_relative "../tracker_helper"

class FragmentsTest < Minitest::Test
  include BuildHelper
  include TrackerHelper

  def translate(ruby, model: "Task")
    translator = Rutile::Build::Translator.new(tracker, "snippet.rb", Rutile::Build::Uses.new, env: :model, model:,
                                                                                               self_var: Rutile::Build::Names.snake(model))
    translator.body(Prism.parse(ruby).value.statements, :unit).first.join("\n")
  end

  def refused(message, &)
    error = assert_raises(Rutile::Build::Unsupported, &)
    assert_includes error.message, message
  end

  # scope :search, ->(query) { where("title ILIKE ?", "%#{sanitize_sql_like(query)}%") }
  def test_a_search_scope_binds_an_escaped_pattern
    rust = Rutile::Build::Scopes.for_model(tracker, Rutile::Build::Uses.new, "Task")
    assert_rust_includes rust, <<~RUST
      // app/models/task.rb:13
      fn search(self, query: String) -> Self {
          self.where_sql("title ILIKE ?", vec![format!("%{}%", sanitize_sql_like(&query)).into()])
      }
    RUST
  end

  # tasks#index: tasks = tasks.search(params[:q]) if params[:q].present?
  # (with its last line, a map block, swapped for a plain render)
  def test_a_param_passed_where_a_string_is_wanted_must_be_one
    app = scratch_app({ "app/controllers/tasks_controller.rb" => ->(ruby) { ruby.sub(/render json: tasks\.map.*$/, "render json: tasks") } },
                      from: TrackerHelper::APP, manifest: TrackerHelper.manifest, diagnostics: Rutile::Build::Diagnostics.new)
    rust = Rutile::Build::ControllerFile.new(app, "TasksController").to_rust
    refute app.diagnostics.problems.any? { _1.start_with?("app/controllers/tasks_controller.rb:") && _1.include?(":8:") }
    assert_rust_includes rust, 'tasks = tasks.search(req.params.value("q").to_str()?);'
  end

  def test_interpolation_formats_and_escapes_braces
    assert_rust_includes translate('x = "a"; found = Task.where("title = ?", "{#{x}}-#{1}")'),
                         'Task::all().where_sql("title = ?", vec![format!("{{{}}}-{}", x, 1).into()])'
  end

  def test_fragments_that_would_bind_wrong_are_refused
    refused("a SQL fragment with 2 ? and 1 value") { translate('found = Task.where("a = ? AND b = ?", 1)') }
    refused("a SQL fragment with $") { translate('found = Task.where("a = $1")') }
    refused("sanitize_sql_like with int") { translate("found = Task.sanitize_sql_like(1)") }
    refused("passing int to scope :search's query (str)") { translate("found = Task.search(1)") }
    refused("interpolating int or nil") { translate('found = Task.where("title = ?", "#{estimate}")') }
  end

  # `.into()` binds tighter than `-`, so an arithmetic bind keeps its parentheses.
  def test_an_arithmetic_bind_keeps_its_grouping
    assert_rust_includes translate('found = Task.where("estimate > ?", 3 - 1)'), "vec![(3 - 1).into()]"
  end
end
