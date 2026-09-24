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
end
