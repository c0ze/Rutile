require_relative "../introspect_helper"

class ControllersTest < Minitest::Test
  include IntrospectHelper

  def test_lists_app_controllers_only
    assert_equal %w[ApplicationController CommentsController PostsController UsersController],
                 manifest["controllers"].map { _1["name"] }
  end

  def test_superclass_source_and_actions
    posts = controller("PostsController")
    assert_equal "ApplicationController", posts["superclass"]
    assert_equal({ "path" => "app/controllers/posts_controller.rb", "line" => 1 }, posts["source"])
    assert_equal %w[create destroy index show update], posts["actions"]
    assert_equal [], controller("ApplicationController")["actions"]
  end

  def test_before_action_only_becomes_an_actions_condition
    assert_equal(
      [{
        "kind" => "before",
        "filter" => { "method" => "set_post", "origin" => "app",
                      "source" => { "path" => "app/controllers/posts_controller.rb", "line" => 37 } },
        "if" => [{ "actions" => %w[destroy show update] }],
        "unless" => []
      }],
      controller("PostsController")["filters"]
    )
  end

  def test_rescue_handlers_are_inherited
    assert_equal(
      [{ "exception" => "ActiveRecord::RecordNotFound",
         "handler" => { "method" => "not_found", "origin" => "app",
                        "source" => { "path" => "app/controllers/application_controller.rb", "line" => 6 } } }],
      controller("PostsController")["rescue_handlers"]
    )
  end

  def test_param_wrapping
    assert_equal(
      { "format" => ["json"], "name" => "post",
        "include" => %w[body comments_count created_at id published_at status title updated_at user_id],
        "exclude" => nil },
      controller("PostsController")["param_wrapping"]
    )
  end
end
