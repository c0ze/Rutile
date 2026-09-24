require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.test_files = FileList["test/**/*_test.rb"]
end

# The introspection tests boot examples/blog, which needs its database.
task test: "example:blog_db"

# Each example's own suite, whatever EXAMPLE the shell has set.
%w[blog tracker].each do |name|
  namespace(name) do
    desc "Run the #{name} example's own test suite"
    task(:test) { sh({ "EXAMPLE" => name }, "bundle", "exec", "rake", "example:test") }
  end
end

task default: %w[test blog:test tracker:test]
