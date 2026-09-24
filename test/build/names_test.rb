require "minitest/autorun"
require_relative "../../lib/rutile/build"

class NamesTest < Minitest::Test
  Names = Rutile::Build::Names

  def test_case_conversions
    assert_equal "posts_controller", Names.snake("PostsController")
    assert_equal "PostsController", Names.camel("posts_controller")
    assert_equal "COMMENTS", Names.constant("comments")
  end

  def test_ruby_method_names
    assert_equal "is_published", Names.method("published?")
    assert_equal "find_by_bang", Names.method(:find_by!)
    assert_equal "save", Names.method("save")
  end

  def test_string_literals
    assert_equal '"say \"hi\"\\n"', Names.str(%(say "hi"\n))
    assert_equal '"é"', Names.str("é")
    assert_equal 'r"\A[a-z]\z"', Names.raw('\A[a-z]\z')
    assert_equal 'r#"a"b"#', Names.raw('a"b')
    assert_equal '&["id", "name"]', Names.str_slice(%w[id name])
  end
end
