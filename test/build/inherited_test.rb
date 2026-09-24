require_relative "../build_helper"
require_relative "../tracker_helper"

class InheritedTest < Minitest::Test
  include BuildHelper
  include TrackerHelper

  def controller(name, app = tracker) = [Rutile::Build::ControllerFile.new(app, name).to_rust, app.diagnostics.problems]

  # ApplicationController's before_action runs in every controller, and
  # halts with its response.
  def test_an_inherited_filter_halts_with_its_response
    rust, problems = controller("ProjectsController")
    assert_rust_includes rust, <<~RUST
      // before_action :authenticate (app/controllers/application_controller.rb)
      if let Some(response) = self.authenticate(req)? {
          return Ok(Some(response));
      }
    RUST
    assert_rust_includes rust, <<~RUST
      // app/controllers/application_controller.rb:11
      fn authenticate(&mut self, req: &mut Request) -> Result<Option<Response>> {
          let header = req.header("X-Api-Token").unwrap_or_default();
          self.current_user = User::find_by(&mut req.ctx, "api_token", header)?;
          if self.current_user.is_some() {
              Ok(None)
          } else {
              Ok(Some(Response::head(401)))
          }
      }
    RUST
    assert_rust_includes rust, "current_user: Option<Handle<User>>,"
    refute problems.any? { _1.include?("before_action") || _1.include?("current_user") }, problems.join("\n")
  end

  # skip_before_action :authenticate, only: :create
  def test_a_skipped_filter_is_guarded_by_the_resolved_chain
    rust, = controller("UsersController")
    assert_rust_includes rust, 'if !matches!(action, "create") { if let Some(response) = self.authenticate(req)? {'
  end

  def test_a_filter_that_renders_early_is_refused
    app = scratch_app({ "app/controllers/posts_controller.rb" => lambda do |ruby|
      ruby.sub("@post = Post.find(params[:id])", "head :forbidden if params[:id].blank?\n    @post = Post.find(params[:id])")
    end })
    error = assert_raises(Rutile::Build::Unsupported) { Rutile::Build::ControllerFile.new(app, "PostsController").to_rust }
    assert_equal "app/controllers/posts_controller.rb:38: render or head anywhere but at the end of an action or filter " \
                 "isn't supported yet", error.message
  end

  # memberships.create!(user: owner, role: :admin): build through the
  # association, set a belongs_to and an enum, save or raise.
  def test_create_through_an_association_with_a_hash
    app = tracker
    rust = Rutile::Build::ModelFile.new(app, "Project").to_rust
    assert_rust_includes rust, <<~RUST
      let membership = Project::MEMBERSHIPS.build(ctx, project, Membership::new_record())?;
      let owner = Project::OWNER.get(ctx, project)?;
      if let Some(owner) = owner {
          Membership::USER.set(ctx, membership, owner)?;
      } else {
          ctx[membership].user_id = None;
      }
      ctx[membership].role = Some("admin".to_string());
      ctx.save_bang(membership)?;
      Ok(())
    RUST
    refute app.diagnostics.problems.any? { _1.include?("create!") }, app.diagnostics.problems.join("\n")
  end

  def test_create_bang_with_params
    rust, problems = controller("UsersController")
    assert_rust_includes rust, "req.ctx.build(User::from_attributes(&attributes)?)"
    assert_rust_includes rust, "req.ctx.save_bang("
    refute problems.any? { _1.include?("create!") }, problems.join("\n")
  end

  # The model file refuses a has_many :through, so its callers must too;
  # otherwise they'd compile against a constant that was never emitted.
  def test_calls_through_a_refused_association_are_refused
    translator = Rutile::Build::Translator.new(tracker, "snippet.rb", Rutile::Build::Uses.new, env: :model, model: "User",
                                                                                                self_var: "user")
    error = assert_raises(Rutile::Build::Unsupported) { translator.body(Prism.parse("projects.to_a").value.statements, :unit) }
    assert_equal "snippet.rb:1: has_many :projects with through isn't supported yet", error.message
  end

  def tracker_scratch(edits) = scratch_app(edits, from: TrackerHelper::APP, manifest: TrackerHelper.manifest,
                                                  diagnostics: Rutile::Build::Diagnostics.new)

  # Ruby finds the subclass's method before ApplicationController's reader.
  def test_a_subclass_method_beats_an_inherited_reader
    app = tracker_scratch({ "app/controllers/users_controller.rb" => lambda do |ruby|
      ruby.sub("  private\n", "  private\n\n  def current_user = @current_user\n")
          .sub("render json: User.find(params[:id])", "render json: current_user")
    end })
    rust = Rutile::Build::ControllerFile.new(app, "UsersController").to_rust
    assert_includes rust, "fn current_user(&mut self"
    assert_includes rust, "self.current_user(req)?"
  end

  # A String field is cloned out of the controller, not moved.
  def test_an_inherited_string_reader_is_cloned
    app = tracker_scratch({
      "app/controllers/application_controller.rb" => lambda do |ruby|
        ruby.sub("attr_reader :current_user", "attr_reader :current_user, :token")
            .sub("    head :unauthorized", "    @token = request.headers[\"X-Api-Token\"]\n    head :unauthorized")
      end,
      "app/controllers/users_controller.rb" => ->(ruby) { ruby.sub("render json: User.find(params[:id]).as_json(only: %i[id name email])", "render json: { token: token, none: nil }") }
    })
    rust = Rutile::Build::ControllerFile.new(app, "UsersController").to_rust
    assert_rust_includes rust, 'json!({ "token": self.token.clone(), "none": null })'
    assert_empty app.diagnostics.problems.grep(/users_controller/)
  end

  def test_nil_into_an_ivar_is_refused
    app = tracker_scratch({ "app/controllers/application_controller.rb" => ->(ruby) { ruby.sub("    head :unauthorized", "    @token = nil\n    head :unauthorized") } })
    Rutile::Build::ControllerFile.new(app, "UsersController").to_rust
    assert_includes app.diagnostics.problems, "app/controllers/application_controller.rb:13: assigning nil to @token isn't supported yet"
  end

  def test_return_in_a_callback_block_is_refused
    app = scratch_app({ "app/models/user.rb" => ->(ruby) { ruby.sub("before_validation { self.email = email.to_s.strip.downcase }", "before_validation { return if email.nil? }") } })
    error = assert_raises(Rutile::Build::Unsupported) { Rutile::Build::ModelFile.new(app, "User").to_rust }
    assert_equal "app/models/user.rb:5: return inside a block isn't supported yet", error.message
  end
end
