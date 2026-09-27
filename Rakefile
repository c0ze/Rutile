require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.test_files = FileList["test/**/*_test.rb"]
end

# The introspection and build tests boot both examples, which need their databases.
task test: %w[example:blog_db example:tracker_db example:store_db]

# Each example's own suite, whatever EXAMPLE the shell has set.
%w[blog tracker store].each do |name|
  namespace(name) do
    desc "Run the #{name} example's own test suite"
    task(:test) { sh({ "EXAMPLE" => name }, "bundle", "exec", "rake", "example:test") }
  end
end

task default: %w[test blog:test tracker:test store:test]
