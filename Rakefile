require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.test_files = FileList["test/**/*_test.rb"]
end

# The introspection tests boot examples/blog, which needs its database.
task test: "example:db"

task default: %i[test example:test]
