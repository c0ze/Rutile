require_relative "../build_helper"
require_relative "../tracker_helper"

# `map` with a block over a relation, `merge` on a hash, and rendering the
# list `map` gives.
class BlocksTest < Minitest::Test
  include BuildHelper
  include TrackerHelper

  # `ruby` as an action body in the tracker, with no ivars or helpers.
  def action(ruby, app = tracker)
    controller = Rutile::Build::ApplicationControllerFile.new(app)
    translator = Rutile::Build::Translator.new(app, "snippet.rb", Rutile::Build::Uses.new, env: :controller, controller:)
    translator.body(Prism.parse(ruby).value.statements, :response).first.join("\n")
  end

  def refused(message, ruby)
    error = assert_raises(Rutile::Build::Unsupported) { action(ruby) }
    assert_equal "snippet.rb:#{message} isn't supported yet", error.message
  end

  def test_the_trackers_task_list
    rust = Rutile::Build::ControllerFile.new(tracker, "TasksController").to_rust
    assert_rust_includes rust, <<~RUST
      let records = tasks.load(&mut req.ctx)?;
      let mut mapped = Vec::with_capacity(records.len());
      for task in records {
          let value = AsJson::<Task>::new().render(&mut req.ctx, task)?;
          mapped.push(merge(value, json!({ "overdue": Task::is_overdue(&mut req.ctx, task)? })));
      }
      Ok(Response::json(status::OK, Json::Array(mapped)))
    RUST
  end

  # The body runs in order, each statement once per record; a local it
  # assigns first stays inside it.
  def test_a_block_with_statements_and_scalar_values
    assert_rust_includes action(<<~RUBY), <<~RUST
      titles = Task.where(status: :done).map do |task|
        title = task.title.to_s
        title.strip
      end
      render json: titles
    RUBY
      let records = Task::all().where_eq("status", "done").load(&mut req.ctx)?;
      let mut mapped = Vec::with_capacity(records.len());
      for task in records {
          let title = req.ctx[task].title.clone().unwrap_or_default();
          mapped.push(title.strip());
      }
      let titles = mapped;
      Ok(Response::json(status::OK, Json::from(titles.clone())))
    RUST
    # Outside the block `title` isn't a local, so it's a method call.
    refused("4: title in a controller", "Task.all.map { |t| title = t.title.to_s\n title }\n\nrender json: title")
  end

  def test_a_list_of_records_renders_each
    assert_rust_includes action("render json: Task.all.map { |task| task }"),
                         "Ok(Response::json(status::OK, AsJson::<Task>::new().render_all(&mut req.ctx, &mapped)?))"
    assert_rust_includes action("render json: Task.all.map { |task| task.estimate }"), "Json::from(mapped)"
  end

  # A list in a local can be rendered twice; an unused block parameter is
  # an underscored loop variable.
  def test_a_list_rendered_twice_and_an_unused_parameter
    rust = action("titles = Task.all.map { |t| 1 }\nrender json: { a: titles, b: titles }")
    assert_rust_includes rust, "for _t in records { mapped.push(1); }"
    assert_rust_includes rust, 'json!({ "a": Json::from(titles.clone()), "b": Json::from(titles.clone()) })'
  end

  # Only what the generated code names is imported: here `Project::TASKS`,
  # never Task.
  def test_a_list_from_an_association_imports_only_what_it_names
    app = scratch_app({ "app/controllers/projects_controller.rb" => lambda do |ruby|
      ruby.sub("render json: @project.as_json(include: { tasks: { only: %i[id title status] } })",
               "render json: @project.tasks.map { |task| task.title }")
    end }, diagnostics: Rutile::Build::Diagnostics.new, manifest: TrackerHelper.manifest, from: TrackerHelper::APP)
    rust = Rutile::Build::ControllerFile.new(app, "ProjectsController").to_rust
    assert_includes rust, "use crate::models::{Project, ProjectScopes, User};"
  end

  def test_blocks_it_cant_run
    refused("1: a map block without one plain parameter", "render json: Task.all.map { _1.title }")
    refused("1: a map block without one plain parameter", "render json: Task.all.map { |a, b| a }")
    refused("1: a map block without one plain parameter", "render json: Task.all.map(&:title)")
    refused("1: map over str", 'render json: "abc".map { |c| c }')
    refused("1: return inside a block", "render json: Task.all.map { |t| return if t.title\n t }")
    refused("1: an empty map block", "render json: Task.all.map { |t| }")
    refused("1: a map block giving nil", "render json: Task.all.map { |t| nil }")
    refused("1: a map block giving a relation of Task", "render json: Task.all.map { |t| Task.all }")
    refused("1: a block passed to each", "Task.all.each { |t| t.title }\nhead :ok")
    refused("1: render json: an array of hashes that may be nil",
            "render json: Task.all.map { |t| t.title ? t.as_json : nil }")
  end

  def test_merge_on_a_hash_as_json_or_a_literal_made
    assert_rust_includes action('render json: { a: 1 }.merge("b" => 2)'),
                         'Ok(Response::json(status::OK, merge(json!({ "a": 1 }), json!({ "b": 2 }))))'
    assert_rust_includes action("render json: Task.find(1).as_json.merge(Task.find(2).as_json)"), "merge(value, AsJson::<Task>::new().render(&mut req.ctx, task_2)?)"
    refused("2: merge on a value that isn't a hash from as_json or a literal",
            "json = Task.find(1).as_json\nrender json: json.merge(a: 1)")
    refused("1: merge on a value that isn't a hash from as_json or a literal", "render json: Task.all.as_json.merge(a: 1)")
  end

  # Ruby keeps "title" and :title apart and Rails' JSON encoder raises on
  # the pair, so they never meet; other symbol keys merge as Ruby does.
  def test_merge_keeps_string_and_symbol_keys_apart
    assert_rust_includes action("render json: Task.find(1).as_json(only: :id).merge(overdue: true)"),
                         'merge(AsJson::<Task>::new().only(&["id"]).render(&mut req.ctx, task)?, json!({ "overdue": true }))'
    refused("1: merge with the symbol key title, which the hash already has as a string,",
            'render json: Task.find(1).as_json.merge(title: "hidden")')
    refused("1: merge with the string key a, which the hash already has as a symbol,", 'render json: { a: 1 }.merge("a" => 2)')
    refused('1: a hash with both "a" and :a', 'render json: { a: 1, "a" => 2 }')
    assert_rust_includes action("render json: Task.find(1).as_json(except: :title).merge(title: 1)"), '"title": 1'
  end

  # The receiver is read before the argument runs, as Ruby evaluates them.
  def test_merge_reads_the_receiver_first
    ruby = "task = Task.find(1)\nrender json: { before: task.title }.merge(\"after\" => Task.find(2).title)"
    assert_rust_includes action(ruby), <<~RUST
      let value = json!({ "before": req.ctx[task].title.clone() });
      let task_2 = Task::find(&mut req.ctx, 2)?;
    RUST
  end
end
