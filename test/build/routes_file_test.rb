require_relative "../build_helper"

class RoutesFileTest < Minitest::Test
  include BuildHelper

  def test_routes_in_match_order_with_their_constraint
    rust = Rutile::Build::RoutesFile.new(app).to_rust
    assert_includes rust, "use crate::controllers::{CommentsController, PostsController, UsersController};"
    assert_rust_includes rust, <<~RUST
      Router::new()
          .default_headers(&[("X-Frame-Options", "SAMEORIGIN"), ("X-XSS-Protection", "0"), ("X-Content-Type-Options", "nosniff"),
                             ("X-Permitted-Cross-Domain-Policies", "none"), ("Referrer-Policy", "strict-origin-when-cross-origin")])
          // GET /users/lookup(.:format) users#lookup
          .get("/users/lookup(.:format)", action("lookup", UsersController::lookup))
          .constraint(users_lookup_constraint)
          // POST /users(.:format) users#create
          .post("/users(.:format)", action("create", UsersController::create))
          // GET /users/:id(.:format) users#show
          .get("/users/:id(.:format)", action("show", UsersController::show))
    RUST
    assert_rust_includes rust, '.patch("/posts/:id(.:format)", action("update", PostsController::update))'
    assert_rust_includes rust, '.get("/up(.:format)", Box::new(health))'
    assert_rust_includes rust, <<~RUST
      // config/routes.rb:3
      fn users_lookup_constraint(req: &Request) -> bool {
          req.query.get("email").cloned().is_present()
      }
    RUST
  end

  # A public method of ApplicationController is an action of every
  # controller, but a controller compiles only its own file's actions.
  def test_an_action_from_outside_the_controllers_file_is_refused
    manifest = JSON.parse(IntrospectHelper.manifest_text)
    manifest["controllers"].each { _1["actions"] = (_1["actions"] + ["ping"]).sort }
    ping = manifest["routes"][2].merge("path" => "/ping(.:format)", "action" => "ping", "name" => nil)
    manifest["routes"] += [ping.merge("controller" => "posts"), ping.merge("controller" => "application")]
    edit = ->(ruby) { ruby.sub("  private\n", "  def ping = head(:ok)\n\n  private\n") }
    scratch = scratch_app({ "app/controllers/application_controller.rb" => edit }, manifest:,
                                                                                  diagnostics: Rutile::Build::Diagnostics.new)
    Rutile::Build::RoutesFile.new(scratch).to_rust
    assert_equal [
      "config/routes.rb: GET /ping(.:format) application#ping: ApplicationController as a route's controller isn't supported yet",
      "config/routes.rb: GET /ping(.:format) posts#ping: an action PostsController inherits from ApplicationController isn't supported yet"
    ], scratch.diagnostics.problems
    assert_equal %w[CommentsController PostsController UsersController], Rutile::Build::ControllerFile.all(scratch).map(&:name)
  end

  def test_route_requirements_are_unsupported
    broken = app_with { |m| m["routes"][2]["requirements"] = { "id" => { "regexp" => "\\d+", "options" => 0 } } }
    error = assert_raises(Rutile::Build::Unsupported) { Rutile::Build::RoutesFile.new(broken).to_rust }
    assert_equal "config/routes.rb: GET /users/:id(.:format) users#show: requirements isn't supported yet", error.message
  end

  # `match "*path", to: "errors#missing", via: :all` has the verb "", which
  # used to split into no routes at all, silently.
  def test_a_route_for_every_verb_is_refused
    catch_all = app_with do |m|
      m["routes"] << m["routes"][2].merge("verb" => "", "path" => "/*path(.:format)")
    end
    error = assert_raises(Rutile::Build::Unsupported) { Rutile::Build::RoutesFile.new(catch_all).to_rust }
    assert_equal "config/routes.rb:  /*path(.:format) users#show: via: :all isn't supported yet", error.message
  end

  def test_a_route_without_a_controller_is_refused
    redirect = app_with do |m|
      m["routes"] << { "verb" => "GET", "path" => "/old(.:format)", "controller" => nil, "action" => nil, "name" => nil,
                       "requirements" => {}, "request_constraints" => {}, "callable_constraints" => [] }
    end
    error = assert_raises(Rutile::Build::Unsupported) { Rutile::Build::RoutesFile.new(redirect).to_rust }
    assert_equal "config/routes.rb: GET /old(.:format): a route without a controller (a redirect or a mount) isn't supported yet",
                 error.message
  end
end
