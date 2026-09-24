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
end
