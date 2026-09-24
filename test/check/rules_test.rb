require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../../lib/rutile"

class RulesTest < Minitest::Test
  def findings(files)
    Dir.mktmpdir do |root|
      files.each do |path, ruby|
        FileUtils.mkdir_p(File.dirname(File.join(root, path)))
        File.write(File.join(root, path), ruby)
      end
      diagnostics = Rutile::Build::Diagnostics.new
      Rutile::Check::Rules.scan(root, diagnostics)
      diagnostics.problems
    end
  end

  def test_the_design_rules
    ruby = <<~RUBY
      class Magic < ApplicationRecord
        @@count = 0
        def method_missing(name, *args) = super
        def respond_to_missing?(name, all = false) = super
        def call(name) = public_send(name)
        def run(code) = eval(code)
        def patch = self.class.class_eval("def x; end")
        define_method(:shout) { title.upcase }
        def remember; $last = self; end
      end
    RUBY
    assert_equal [
      "app/models/magic.rb:2: the class variable @@count can't be compiled; use a constant, Rails.cache, or the database",
      "app/models/magic.rb:3: def method_missing can't be compiled; use explicit methods",
      "app/models/magic.rb:4: def respond_to_missing? can't be compiled; use explicit methods",
      "app/models/magic.rb:5: public_send with a computed name can't be compiled; use a case over the known names",
      "app/models/magic.rb:6: eval can't be compiled; use a method, or a block form the compiler understands",
      "app/models/magic.rb:7: class_eval with a string can't be compiled; use a method, or a block form the compiler understands",
      "app/models/magic.rb:8: define_method can't be compiled; use a literal list of methods",
      "app/models/magic.rb:9: assigning the global $last can't be compiled; use a constant, Rails.cache, or the database"
    ], findings("app/models/magic.rb" => ruby)
  end

  def test_reopening_a_core_class
    assert_equal ["lib/core_ext.rb:1: reopening String can't be compiled; use a helper module"],
                 findings("lib/core_ext.rb" => "class String\n  def shout = upcase\nend\n")
  end

  def test_what_is_fine
    ruby = <<~RUBY
      class Loud < String; end
      module Tools
        class String; end
      end
      class Fine < ApplicationRecord
        def a = send(:title)
        def b = public_send("body")
        def c = instance_eval { title }
        def d = $stdout.puts("hi")
      end
    RUBY
    assert_empty findings("app/models/fine.rb" => ruby)
  end

  def test_a_file_that_does_not_parse
    assert_match %r{\Aapp/models/broken.rb: }, findings("app/models/broken.rb" => "class Broken\n  def x(\nend\n").first
  end
end
