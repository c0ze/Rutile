require_relative "../build_helper"
require_relative "../tracker_helper"

# The tracker's `tasks.due_on`: a date column, Date.current and Date.today,
# and comparisons between dates.
class DateTest < Minitest::Test
  include BuildHelper
  include TrackerHelper

  def tracker_with(diagnostics: nil)
    manifest = JSON.parse(JSON.generate(TrackerHelper.manifest))
    yield manifest
    Rutile::Build::App.new(TrackerHelper::APP, manifest, diagnostics:)
  end

  def callback(ruby, app: tracker)
    translator = Rutile::Build::Translator.new(app, "snippet.rb", Rutile::Build::Uses.new, env: :model, model: "Task",
                                                                                            self_var: "task")
    translator.body(Prism.parse(ruby).value.statements, :unit).first.join("\n")
  end

  def test_a_date_column_is_a_date_field
    rust = Rutile::Build::ModelFile.new(tracker, "Task").to_rust
    assert_rust_includes rust, "estimate: i64, due_on: Date, completed_at: Time,"
    assert_match(/^use rustonrails::\{.*\bDate\b.*\};$/, rust)
  end

  def test_date_current_and_comparisons
    assert_rust_includes callback("self.notes = \"late\" if due_on.present? && due_on < Date.current"),
                         'if ctx[task].due_on.is_some() && ctx[task].due_on.ok_or(Error::Nil { what: "<" })? < today() {'
    assert_rust_includes callback("self.due_on = Date.today"), "ctx[task].due_on = Some(local_today());"
    assert_rust_includes callback("self.notes = \"today\" if due_on == Date.current"),
                         "if ctx[task].due_on == Some(today()) {"
  end

  # Ruby can't compare a Date with a Time.
  def test_a_date_against_a_time_is_refused
    error = assert_raises(Rutile::Build::Unsupported) { callback("self.notes = \"x\" if due_on < Time.current") }
    assert_equal "snippet.rb:1: < between date and time isn't supported yet", error.message
  end

  # Date.current is today in the app's zone; the runtime's is UTC.
  def test_date_current_in_another_zone_is_refused
    tokyo = tracker_with { _1["config"]["time_zone"] = "Tokyo" }
    error = assert_raises(Rutile::Build::Unsupported) { callback("self.due_on = Date.current", app: tokyo) }
    assert_equal "snippet.rb:1: Date.current with config.time_zone Tokyo isn't supported yet", error.message
  end

  # The struct can't hold a date default yet, and INSERT would write NULL.
  def test_a_date_column_default_is_refused
    app = tracker_with(diagnostics: Rutile::Build::Diagnostics.new) do |manifest|
      tasks = manifest["tables"].find { _1["name"] == "tasks" }
      tasks["columns"].find { _1["name"] == "due_on" }["default"] = "2026-01-01"
    end
    Rutile::Build::ModelFile.new(app, "Task").to_rust
    assert_includes app.diagnostics.problems, "app/models/task.rb: the default 2026-01-01 on the date column due_on isn't supported yet"
  end
end
