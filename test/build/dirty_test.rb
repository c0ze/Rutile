require_relative "../build_helper"
require_relative "../tracker_helper"

# `will_save_change_to_x?` is RustOnRails' attribute_changed, in a callback
# condition or an expression; `saved_change_to_x?` needs the last save,
# which the runtime doesn't keep.
class DirtyTest < Minitest::Test
  include BuildHelper
  include TrackerHelper

  def rust(app = tracker) = Rutile::Build::ModelFile.new(app, "Task").to_rust

  # Task's before_save with its condition replaced.
  def tracker_with(key, method)
    manifest = JSON.parse(JSON.generate(TrackerHelper.manifest))
    task = manifest["models"].find { _1["name"] == "Task" }
    stamp = task["callbacks"]["save"].find { _1.dig("filter", "method") == "stamp_completion" }
    stamp["if"] = []
    stamp[key] = [{ "method" => method, "origin" => "missing", "source" => nil }]
    Rutile::Build::App.new(TrackerHelper::APP, manifest, diagnostics: Rutile::Build::Diagnostics.new)
  end

  def callback(ruby)
    translator = Rutile::Build::Translator.new(tracker, "snippet.rb", Rutile::Build::Uses.new, env: :model, model: "Task",
                                                                                              self_var: "task")
    translator.body(Prism.parse(ruby).value.statements, :unit).first.join("\n")
  end

  def test_a_callback_condition
    assert_rust_includes rust, <<~RUST
      // before_save :stamp_completion (app/models/task.rb:29)
      .before_save(Task::stamp_completion)
      .when(|ctx, task| ctx.attribute_changed(task, "status"))
    RUST
    assert_rust_includes rust(tracker_with("unless", "will_save_change_to_title?")),
                         '.unless(|ctx, task| ctx.attribute_changed(task, "title"))'
  end

  def test_an_expression
    assert_rust_includes callback("self.completed_at = nil if will_save_change_to_status? && !will_save_change_to_title?"),
                         'if ctx.attribute_changed(task, "status") && !(ctx.attribute_changed(task, "title")) {'
  end

  def test_saved_change_to_is_refused
    app = tracker_with("if", "saved_change_to_status?")
    rust(app)
    assert_includes app.diagnostics.problems, "app/models/task.rb: before_save :stamp_completion with the condition " \
                                              ":saved_change_to_status?, which needs the last save's changes, isn't supported yet"
    error = assert_raises(Rutile::Build::Unsupported) { callback("self.notes = nil if saved_change_to_status?") }
    assert_equal "snippet.rb:1: saved_change_to_status?, which needs the last save's changes, isn't supported yet", error.message
  end

  # Only columns have them; `from:`/`to:` aren't mapped.
  def test_other_dirty_forms_are_refused
    app = tracker_with("if", "will_save_change_to_project?")
    rust(app)
    assert_includes app.diagnostics.problems,
                    "app/models/task.rb: before_save :stamp_completion with the condition :will_save_change_to_project? isn't supported yet"
    error = assert_raises(Rutile::Build::Unsupported) { callback("self.notes = nil if will_save_change_to_status?(to: \"done\")") }
    assert_equal "snippet.rb:1: will_save_change_to_status? on Task isn't supported yet", error.message
  end
end
