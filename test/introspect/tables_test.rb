require_relative "../introspect_helper"

class TablesTest < Minitest::Test
  include IntrospectHelper

  def test_lists_app_tables_only
    assert_equal %w[comments posts users], manifest["tables"].map { _1["name"] }
  end

  def test_column_details
    posts = table("posts")
    assert_equal "id", posts["primary_key"]
    assert_equal(
      { "name" => "status", "type" => "integer", "sql_type" => "integer", "null" => false,
        "default" => "0", "default_function" => nil, "limit" => 4, "precision" => nil, "scale" => nil },
      column(posts, "status")
    )
    published_at = column(posts, "published_at")
    assert_equal ["datetime", true, 6], published_at.values_at("type", "null", "precision")
  end

  def test_columns_keep_database_order
    assert_equal %w[id user_id title body status published_at comments_count created_at updated_at],
                 table("posts")["columns"].map { _1["name"] }
  end
end
