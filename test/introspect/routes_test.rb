require_relative "../introspect_helper"

class RoutesTest < Minitest::Test
  include IntrospectHelper

  def route(verb, path)
    manifest.fetch("routes").find { _1["verb"] == verb && _1["path"] == path } || flunk("no route #{verb} #{path}")
  end

  def test_resource_routes
    assert_equal(
      { "verb" => "GET", "path" => "/posts(.:format)", "controller" => "posts", "action" => "index",
        "name" => "posts", "requirements" => {}, "request_constraints" => {}, "callable_constraints" => [] },
      route("GET", "/posts(.:format)")
    )
    assert_equal ["posts", "update", nil], route("PATCH", "/posts/:id(.:format)").values_at("controller", "action", "name")
  end

  def test_nested_routes
    assert_equal ["comments", "create"],
                 route("POST", "/posts/:post_id/comments(.:format)").values_at("controller", "action")
  end

  def test_api_resources_have_no_new_or_edit
    refute manifest["routes"].any? { %w[new edit].include?(_1["action"]) }
  end

  def test_health_check
    assert_equal ["rails/health", "show", "rails_health_check"],
                 route("GET", "/up(.:format)").values_at("controller", "action", "name")
  end

  def test_callable_constraints_are_recorded
    lookup = route("GET", "/users/lookup(.:format)")
    assert_equal [{ "proc" => { "path" => "config/routes.rb", "line" => 3 } }], lookup["callable_constraints"]
    assert_equal({}, lookup["request_constraints"])
  end
end
