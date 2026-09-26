require "fileutils"
require_relative "../build_helper"

class ControllerFileTest < Minitest::Test
  include BuildHelper

  def rust(name) = Rutile::Build::ControllerFile.new(app, name).to_rust

  # `ruby` as an action body in a controller with no ivars or helpers.
  def action(ruby)
    controller = Rutile::Build::ApplicationControllerFile.new(app)
    translator = Rutile::Build::Translator.new(app, "snippet.rb", Rutile::Build::Uses.new, env: :controller, controller:)
    translator.body(Prism.parse(ruby).value.statements, :response).first.join("\n")
  end

  def test_struct_fields_are_the_instance_variables
    assert_rust_includes rust("PostsController"), "#[derive(Default)] pub struct PostsController { post: Option<Handle<Post>>, }"
    assert_rust_includes rust("UsersController"), "#[derive(Default)] pub struct UsersController;"
  end

  def test_wrapping_filters_and_rescue_become_the_controller_trait
    posts = rust("PostsController")
    assert_rust_includes posts, 'Some(("post", &["body", "comments_count", "created_at", "id", "published_at", "status", ' \
                                '"title", "updated_at", "user_id"]))'
    assert_rust_includes posts, 'if matches!(action, "destroy" | "show" | "update") { self.set_post(req)?; } Ok(None)'
    assert_rust_includes posts, "Error::RecordNotFound { .. } => application::not_found(req), other => Err(other),"
    assert_includes posts, "use super::application;"
  end

  def test_index_loads_the_relation_once_and_renders_with_options
    assert_rust_includes rust("PostsController"), <<~RUST
      pub fn index(&mut self, req: &mut Request) -> Result<Response> {
          let posts = Post::all().visible().recent().includes(&Post::USER).limit(20);
          let records = posts.load(&mut req.ctx)?;
          Ok(Response::json(status::OK, AsJson::<Post>::new().include(&Post::USER, AsJson::<User>::new().only(&["id", "name"]))
              .render_all(&mut req.ctx, &records)?))
      }
    RUST
  end

  def test_an_ivar_renders_nil_as_null
    assert_rust_includes rust("PostsController"),
                         "Ok(Response::json(status::OK, AsJson::<Post>::new().render_option(&mut req.ctx, self.post)?))"
  end

  def test_update_evaluates_receiver_then_arguments_once
    assert_rust_includes rust("PostsController"), <<~RUST
      pub fn update(&mut self, req: &mut Request) -> Result<Response> {
          let post = self.post.ok_or(Error::Nil { what: "update" })?;
          let attributes = self.post_params(req)?;
          req.ctx.assign(post, &attributes)?;
          if req.ctx.save(post)? {
    RUST
  end

  def test_create_through_an_association
    assert_rust_includes rust("CommentsController"), <<~RUST
      let post = self.post.ok_or(Error::Nil { what: "comments" })?;
      let attributes = self.comment_params(req)?;
      let comment = Post::COMMENTS.build(&mut req.ctx, post, Comment::from_attributes(&attributes)?)?;
      if req.ctx.save(comment)? {
          Ok(Response::json(status::CREATED, AsJson::<Comment>::new().render(&mut req.ctx, comment)?))
      } else {
          Ok(Response::json(status::UNPROCESSABLE_CONTENT, errors_json(req.ctx.errors(comment))))
      }
    RUST
  end

  def test_helpers_filters_and_params
    users = rust("UsersController")
    assert_rust_includes users, <<~RUST
      fn user_params(&mut self, req: &mut Request) -> Result<Attributes> {
          Ok(req.params.require("user")?.permit(&["name", "email"]))
      }
    RUST
    assert_rust_includes users, 'let user = User::find_by_bang(&mut req.ctx, "email", ' \
                                'req.params.value("email")?.to_s().strip().downcase())?;'
    assert_rust_includes rust("CommentsController"), <<~RUST
      fn set_post(&mut self, req: &mut Request) -> Result<()> {
          self.post = Some(Post::find(&mut req.ctx, req.params.value("post_id")?)?);
          Ok(())
      }
    RUST
  end

  def test_application_controller_handlers_are_functions
    assert_rust_includes Rutile::Build::ApplicationControllerFile.new(app).to_rust, <<~RUST
      // app/controllers/application_controller.rb:6
      pub fn not_found(_req: &mut Request) -> Result<Response> {
          Ok(Response::json(status::NOT_FOUND, json!({ "error": "not found" })))
      }
    RUST
  end

  def test_statuses
    assert_rust_includes action("head :no_content"), "Ok(Response::head(status::NO_CONTENT))"
    assert_rust_includes action("head :forbidden"), "Ok(Response::head(403))"
  end

  def test_render_must_end_the_action
    error = assert_raises(Rutile::Build::Unsupported) { action("render json: { a: 1 }\nhead :ok") }
    assert_equal "snippet.rb:1: render or head anywhere but at the end of an action or filter isn't supported yet", error.message
  end

  # Ruby reads `draft?` before `save` runs; so must the Rust.
  def test_a_hash_keeps_ruby_order_around_writes
    assert_rust_includes action("post = Post.find(params[:id])\nrender json: { was_draft: post.draft?, saved: post.save }"), <<~RUST
      let post = Post::find(&mut req.ctx, req.params.value("id")?)?;
      let was_draft = req.ctx[post].is_draft();
      Ok(Response::json(status::OK, json!({ "was_draft": was_draft, "saved": req.ctx.save(post)? })))
    RUST
  end

  def test_class_level_calls_the_manifest_lacks_are_refused
    Dir.mktmpdir do |root|
      FileUtils.cp_r(File.join(IntrospectHelper::APP, "app"), root)
      path = File.join(root, "app/controllers/posts_controller.rb")
      File.write(path, File.read(path).sub(/^end\s*\z/, "  layout \"x\"\nend\n"))
      moved = Rutile::Build::App.new(root, IntrospectHelper.manifest)
      error = assert_raises(Rutile::Build::Unsupported) { Rutile::Build::ControllerFile.new(moved, "PostsController").to_rust }
      assert_match(%r{\Aapp/controllers/posts_controller.rb:\d+: layout in a class body isn't supported yet\z}, error.message)
    end
  end

  def test_a_before_action_that_renders_halts
    app = scratch_app({ "app/controllers/posts_controller.rb" =>
                          lambda do |ruby|
                            ruby.sub("@post = Post.find(params[:id])", "@post = Post.find(params[:id])\n    head :forbidden if @post.draft?")
                          end })
    assert_rust_includes Rutile::Build::ControllerFile.new(app, "PostsController").to_rust,
                         'if req.ctx[self.post.ok_or(Error::Nil { what: "draft?" })?].is_draft() { ' \
                         "Ok(Some(Response::head(403))) } else { Ok(None) }"
  end

  # Rails ANDs the action lists (`only:` plus a skip_before_action `except:`).
  def test_several_action_conditions_are_all_required
    both = app_with do |m|
      m["controllers"].find { _1["name"] == "PostsController" }["filters"][0]["if"] << { "actions" => ["show"] }
    end
    assert_rust_includes Rutile::Build::ControllerFile.new(both, "PostsController").to_rust,
                         'if matches!(action, "destroy" | "show" | "update") && matches!(action, "show") {'
  end

  def test_a_helper_returning_params_is_refused
    app = scratch_app({ "app/controllers/posts_controller.rb" => ->(ruby) { ruby.sub("params.expect(post: %i[user_id title body status])", "params") } })
    error = assert_raises(Rutile::Build::Unsupported) { Rutile::Build::ControllerFile.new(app, "PostsController").to_rust }
    assert_equal "app/controllers/posts_controller.rb:41: a helper returning params isn't supported yet", error.message
  end

  def test_an_empty_action_list_is_a_constant
    none = app_with { |m| m["controllers"].find { _1["name"] == "PostsController" }["filters"][0]["if"] = [{ "actions" => [] }] }
    assert_rust_includes Rutile::Build::ControllerFile.new(none, "PostsController").to_rust, "if false { self.set_post(req)?; }"
  end
end
