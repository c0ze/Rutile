require "minitest/autorun"
require "open3"

# The example app's rake tasks must stay on the throwaway cluster even when
# the shell exports a connection URL for some other project.
class ExampleTasksTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def test_example_db_ignores_exported_database_urls
    elsewhere = "postgres://postgres@localhost:1/elsewhere"
    env = { "DATABASE_URL" => elsewhere, "PRIMARY_DATABASE_URL" => elsewhere }
    _out, err, status = Open3.capture3(env, "bundle", "exec", "rake", "example:db", chdir: ROOT)
    assert status.success?, err
  end

  # Rutile's own tests introspect the blog, whatever EXAMPLE says.
  def test_rutile_tests_prepare_the_blog_whatever_example_is_set_to
    out, err, status = Open3.capture3({ "EXAMPLE" => "tracker" }, "bundle", "exec", "rake", "-P", chdir: ROOT)
    assert status.success?, err
    prerequisites = out[/^rake test\n((?:    .*\n)*)/, 1].to_s.split.sort
    assert_equal %w[example:blog_db], prerequisites
    default = out[/^rake default\n((?:    .*\n)*)/, 1].to_s.split
    assert_equal %w[test blog:test tracker:test], default
  end
end
