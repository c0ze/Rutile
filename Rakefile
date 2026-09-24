require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.test_files = FileList["test/**/*_test.rb"]
end

# The introspection tests boot examples/blog, which needs its database.
task test: "example:db"

namespace :tracker do
  desc "Run the tracker example's own test suite"
  task(:test) { sh({ "EXAMPLE" => "tracker" }, "bundle", "exec", "rake", "example:test") }
end

task default: %i[test example:test tracker:test]
