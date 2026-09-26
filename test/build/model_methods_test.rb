require_relative "../build_helper"
require_relative "../tracker_helper"

# A model's own methods become functions on the model, taking the Ctx and
# the record, callable from controllers and other models; enum bang
# methods are `update!`.
class ModelMethodsTest < Minitest::Test
  include BuildHelper
  include TrackerHelper

  def model(name, app = tracker) = Rutile::Build::ModelFile.new(app, name).to_rust

  # Models first, as the crate emits them, then the controller.
  def controller(name, app = tracker)
    app.models.each { model(_1["name"], app) }
    Rutile::Build::ControllerFile.new(app, name).to_rust
  end

  def edited(edits) = scratch_app(edits, diagnostics: Rutile::Build::Diagnostics.new, manifest: TrackerHelper.manifest,
                                         from: TrackerHelper::APP)

  def test_public_methods_are_compiled_with_their_return_types
    project = model("Project")
    assert_rust_includes project, <<~RUST
      // app/models/project.rb:13
      pub fn is_archived(ctx: &mut Ctx, project: Handle<Project>) -> Result<bool> {
          Ok(ctx[project].archived_at.is_some())
      }
    RUST
    assert_rust_includes project, <<~RUST
      // app/models/project.rb:15
      pub fn archive_bang(ctx: &mut Ctx, project: Handle<Project>) -> Result<()> {
          ctx[project].archived_at = Some(now());
          Ok(ctx.save_bang(project)?)
      }
    RUST
    assert_rust_includes model("Task"), <<~RUST
      pub fn is_overdue(ctx: &mut Ctx, task: Handle<Task>) -> Result<bool> {
          Ok((ctx[task].due_on.is_some() && ctx[task].due_on.ok_or(Error::Nil { what: "<" })? < today()) && !(ctx[task].is_done()))
      }
    RUST
  end

  def test_controllers_call_them
    assert_rust_includes controller("ProjectsController"),
                         'Project::archive_bang(&mut req.ctx, self.project.ok_or(Error::Nil { what: "archive!" })?)?;'
  end

  def test_an_enum_bang_method_updates_the_attribute
    assert_rust_includes controller("TasksController"), <<~RUST
      let task = self.task.ok_or(Error::Nil { what: "done!" })?;
      req.ctx[task].status = Some("done".to_string());
      req.ctx.save_bang(task)?;
    RUST
  end

  # A private method is compiled when the record calls it on itself.
  def test_a_private_method_its_record_calls
    app = edited("app/models/project.rb" => lambda do |ruby|
      ruby.sub("def archived? = archived_at.present?", "def archived? = archive_time.present?")
          .sub("  private\n", "  private\n\n  def archive_time = archived_at\n\n  def unused = nil.foo\n")
    end)
    project = model("Project", app)
    assert_rust_includes project, "pub fn is_archived(ctx: &mut Ctx, project: Handle<Project>) -> Result<bool> { " \
                                  "Ok(Project::archive_time(ctx, project)?.is_some()) }"
    assert_rust_includes project, "fn archive_time(ctx: &mut Ctx, project: Handle<Project>) -> Result<Option<Time>> {"
    refute_includes project, "fn unused"
    assert_empty app.diagnostics.problems
  end

  def test_a_private_method_from_outside_is_refused
    app = edited("app/models/project.rb" => ->(ruby) { ruby.sub("  private\n", "  private\n\n  def secret = name\n") },
                 "app/controllers/projects_controller.rb" => ->(ruby) { ruby.sub("@project.archive!", "@project.secret") })
    controller("ProjectsController", app)
    assert_equal ["app/controllers/projects_controller.rb:31: the private method secret from outside Project isn't supported yet"],
                 app.diagnostics.problems
  end

  def test_what_a_method_cant_be
    cases = {
      "  def rename(name) = update!(name:)\n" => "app/models/project.rb:27: a model method with parameters and no rbs-inline signature isn't supported yet",
      "  def loop! = loop!\n" => "app/models/project.rb:27: loop! calling itself without a signature declaring what it returns isn't supported yet",
      "  def to_s = name\n  def -@ = name\n" => "app/models/project.rb:28: a model method named -@ isn't supported yet",
      "  def all = name\n" => "app/models/project.rb:27: a model method named all isn't supported yet",
      "  def owner_name = owner\n" => nil
    }
    cases.each do |added, problem|
      app = edited("app/models/project.rb" => ->(ruby) { ruby.sub(/\nend\s*\z/, "\n\n  public\n\n#{added}end\n") })
      model("Project", app)
      assert_equal [problem].compact, app.diagnostics.problems, added
    end
  end

  def add(ruby) = { "app/models/project.rb" => ->(source) { source.sub(/\nend\s*\z/, "\n\n  public\n\n#{ruby}end\n") } }

  # Rails' own code reads a column through its reader and calls Active
  # Record's methods, so replacing one would change what Rails does.
  def test_what_rails_itself_would_call_is_refused
    { "  def name = \"x\"\n" => "name, which replaces the name column's reader,",
      "  def owner = nil\n" => "owner, which replaces the owner association's reader," }.each do |ruby, message|
      app = edited(add(ruby))
      model("Project", app)
      assert_equal ["app/models/project.rb:27: #{message} isn't supported yet"], app.diagnostics.problems
    end
    manifest = JSON.parse(JSON.generate(TrackerHelper.manifest))
    manifest["models"].find { _1["name"] == "Project" }["overrides"] =
      [{ "name" => "readonly?", "source" => { "path" => "app/models/project.rb", "line" => 27 } }]
    app = scratch_app(add("  def readonly? = archived?\n"), diagnostics: Rutile::Build::Diagnostics.new, manifest:,
                                                                from: TrackerHelper::APP)
    model("Project", app)
    assert_equal ["app/models/project.rb:27: readonly?, which replaces Active Record's readonly?, isn't supported yet"],
                 app.diagnostics.problems
  end

  def test_private_with_a_list_of_names
    app = edited(add("  def secret = name\n  private %i[secret]\n").merge(
      "app/controllers/projects_controller.rb" => ->(ruby) { ruby.sub("@project.archive!", "@project.secret") }
    ))
    controller("ProjectsController", app)
    assert_equal ["app/controllers/projects_controller.rb:31: the private method secret from outside Project isn't supported yet"],
                 app.diagnostics.problems
    app = edited(add("  def secret = name\n  private [1]\n"))
    model("Project", app)
    assert_equal ["app/models/project.rb:28: private with an argument that isn't a name or a def isn't supported yet"],
                 app.diagnostics.problems
  end

  def test_names_and_bodies_rust_needs_spelled_differently
    project = model("Project", edited(add("  def ref = name\n  def kind = \"project\"\n")))
    assert_rust_includes project, "pub fn r#ref(ctx: &mut Ctx, project: Handle<Project>) -> Result<Option<String>>"
    assert_rust_includes project, "pub fn kind(_ctx: &mut Ctx, _project: Handle<Project>) -> Result<String>"

    app = edited(add("  def safe_name\n    name\n  rescue\n    nil\n  end\n"))
    model("Project", app)
    assert_equal ["app/models/project.rb:27: rescue or ensure around a whole body isn't supported yet"], app.diagnostics.problems

    app = edited("app/models/task.rb" => ->(ruby) { ruby.sub("  private\n", "  def is_done = true\n\n  private\n") })
    model("Task", app)
    assert_equal ["app/models/task.rb:21: is_done, whose Rust name is_done Rutile gives something else, isn't supported yet"],
                 app.diagnostics.problems
  end

  # `enum ..., instance_methods: false` (or prefix:, suffix:) leaves no `done!`.
  def test_only_the_enum_methods_rails_defined
    manifest = JSON.parse(JSON.generate(TrackerHelper.manifest))
    manifest["models"].find { _1["name"] == "Task" }["enum_methods"] -= %w[done! done?]
    app = Rutile::Build::App.new(TrackerHelper::APP, manifest, diagnostics: Rutile::Build::Diagnostics.new)
    controller("TasksController", app)
    assert_includes app.diagnostics.problems, "app/controllers/tasks_controller.rb:32: done! on Task isn't supported yet"
  end

  def test_enum_methods_and_callbacks_keep_their_meaning
    app = edited("app/models/task.rb" => ->(ruby) { ruby.sub("  private\n", "  def done? = true\n\n  private\n") })
    model("Task", app)
    assert_equal ["app/models/task.rb:21: done?, which redefines an enum method, isn't supported yet"], app.diagnostics.problems

    app = edited("app/controllers/tasks_controller.rb" => ->(ruby) { ruby.sub("@task.done!", "@task.stamp_completion") },
                 "app/models/task.rb" => ->(ruby) { ruby.sub("  private\n\n  def assignee", "  def assignee") })
    controller("TasksController", app)
    assert_includes app.diagnostics.problems,
                    "app/controllers/tasks_controller.rb:32: calling stamp_completion, which is also a callback, isn't supported yet"
  end
end
