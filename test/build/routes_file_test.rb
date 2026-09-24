require_relative "../build_helper"

class RoutesFileTest < Minitest::Test
  include BuildHelper

  def test_routes_in_match_order_with_their_constraint
    rust = Rutile::Build::RoutesFile.new(app).to_rust
    assert_includes rust, "use crate::controllers::{CommentsController, PostsController, UsersController};"
    assert_rust_includes rust, <<~RUST
      Router::new()
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
          req.query.get("email").is_present()
      }
    RUST
  end

  def test_route_requirements_are_unsupported
    broken = app_with { |m| m["routes"][2]["requirements"] = { "id" => { "regexp" => "\\d+", "options" => 0 } } }
    error = assert_raises(Rutile::Build::Unsupported) { Rutile::Build::RoutesFile.new(broken).to_rust }
    assert_equal "config/routes.rb: GET /users/:id(.:format) users#show: requirements isn't supported yet", error.message
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
