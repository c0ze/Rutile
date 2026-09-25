require_relative "../build_helper"

class ConstantsTest < Minitest::Test
  include BuildHelper

  def posts(app) = Rutile::Build::ControllerFile.new(app, "PostsController").to_rust

  def with_message(ruby) = ruby.sub("class PostsController < ApplicationController\n", "\\0  MISSING = \"no such post\"\n")

  def test_a_controller_constant_is_a_rust_const
    app = scratch_app({ "app/controllers/posts_controller.rb" => lambda do |ruby|
      with_message(ruby).sub("render json: @post\n", "render json: { error: MISSING }\n")
    end })
    rust = posts(app)
    assert_rust_includes rust, %(// app/controllers/posts_controller.rb:2\nconst MISSING: &str = "no such post";)
    assert_rust_includes rust, %(json!({ "error": MISSING }))
  end

  # Ruby looks in the class first, then the one it inherits from.
  def test_a_subclass_constant_hides_application_controllers
    app = scratch_app({
      "app/controllers/application_controller.rb" => ->(ruby) { ruby.sub(/^end\n\z/, "  MISSING = \"gone\"\n  LIMIT = 5\nend\n") },
      "app/controllers/posts_controller.rb" => lambda do |ruby|
        with_message(ruby).sub("render json: @post\n", "render json: { error: MISSING, limit: LIMIT }\n")
      end
    })
    rust = posts(app)
    assert_rust_includes rust, %(const MISSING: &str = "no such post";)
    assert_rust_includes rust, "// app/controllers/application_controller.rb:10\nconst LIMIT: i64 = 5;"
    refute_includes rust, '"gone"'
  end

  # ApplicationController's helper reads its own MISSING, the action
  # PostsController's: two consts with one name in posts.rs.
  def test_a_name_meaning_two_things_in_one_file_is_refused
    app = scratch_app({
      "app/controllers/application_controller.rb" => lambda do |ruby|
        ruby.sub(/^end\n\z/, "  MISSING = \"gone\"\n\n  def missing = MISSING\nend\n")
      end,
      "app/controllers/posts_controller.rb" => lambda do |ruby|
        with_message(ruby).sub("render json: @post\n", "render json: { a: MISSING, b: missing }\n")
      end
    })
    error = assert_raises(Rutile::Build::Unsupported) { posts(app) }
    assert_includes error.message, "MISSING, which means two things in this file"
  end

  def test_a_model_constant_in_a_callback
    app = scratch_app({ "app/models/post.rb" => lambda do |ruby|
      ruby.sub("self.published_at ||= Time.current", "self.comments_count = START").sub(/^end\n\z/, "\n  START = 0\nend\n")
    end })
    rust = Rutile::Build::ModelFile.new(app, "Post").to_rust
    assert_rust_includes rust, "const START: i64 = 0;"
    assert_rust_includes rust, "ctx[post].comments_count = Some(START);"
  end

  def test_a_constant_that_isnt_a_literal_is_refused
    app = scratch_app({ "app/controllers/posts_controller.rb" => lambda do |ruby|
      ruby.sub("class PostsController < ApplicationController\n", "\\0  LIMIT = 5 * 4\n")
          .sub("render json: @post\n", "render json: { limit: LIMIT }\n")
    end })
    error = assert_raises(Rutile::Build::Unsupported) { posts(app) }
    assert_includes error.message, "LIMIT, a constant that isn't an integer, string or boolean"
  end

  # A helper returns an owned String: `Ok(MISSING.to_string())`.
  def test_a_helper_returning_a_string_constant
    app = scratch_app({ "app/controllers/posts_controller.rb" => lambda do |ruby|
      with_message(ruby).sub("render json: @post\n", "render json: { error: missing }\n")
                        .sub(/^end\n\z/, "\n  def missing = MISSING\nend\n")
    end })
    assert_rust_includes posts(app), "Ok(MISSING.to_string())"
  end
end
