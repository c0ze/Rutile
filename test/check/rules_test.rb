require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../../lib/rutile"

class RulesTest < Minitest::Test
  def findings(files, homes = {})
    Dir.mktmpdir do |root|
      files.each do |path, ruby|
        FileUtils.mkdir_p(File.dirname(File.join(root, path)))
        File.write(File.join(root, path), ruby)
      end
      diagnostics = Rutile::Build::Diagnostics.new
      Rutile::Check::Rules.scan(root, diagnostics, homes:)
      diagnostics.problems
    end
  end

  # An initializer or lib/ file can change a model the build reads from its
  # own file, or every model through Rails' base class.
  def test_patching_an_app_class_or_rails_from_elsewhere
    homes = { "Post" => "app/models/post.rb" }
    files = {
      "app/models/post.rb" => "class Post < ApplicationRecord\n  include Comparable\nend\n",
      "config/initializers/patch.rb" => "Post.class_eval { def title = \"x\" }\nActiveRecord::Base.include(Module.new)\n",
      "lib/post_ext.rb" => "class Post\n  def title = \"y\"\nend\n"
    }
    assert_equal [
      "config/initializers/patch.rb:1: reopening Post can't be compiled; use a helper module",
      "config/initializers/patch.rb:2: reopening ActiveRecord::Base can't be compiled; use a helper module",
      "lib/post_ext.rb:1: reopening Post outside app/models/post.rb can't be compiled; use that file"
    ], findings(files, homes)
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

  # Other doors to the same room: a singleton class, send, refinements,
  # reflection on the live program, and an initializer.
  def test_reopening_and_reflection_by_other_means
    ruby = <<~RUBY
      class << String
        def loud = 1
      end
      String.send(:include, Comparable)
      module Shout
        refine(String) { def shout = upcase }
      end
      class Peek < ApplicationRecord
        def a = instance_variable_get(:@title)
        def b = Object.const_get(:Post)
        def c = ObjectSpace.each_object(Peek).count
      end
    RUBY
    assert_equal [
      "app/models/peek.rb:1: reopening String can't be compiled; use a helper module",
      "app/models/peek.rb:4: reopening String can't be compiled; use a helper module",
      "app/models/peek.rb:6: refine can't be compiled; use a helper module",
      "app/models/peek.rb:9: instance_variable_get can't be compiled; use explicit methods and attributes",
      "app/models/peek.rb:10: const_get can't be compiled; use explicit methods and attributes",
      "app/models/peek.rb:11: ObjectSpace can't be compiled; use explicit references"
    ], findings("app/models/peek.rb" => ruby)
    assert_equal ["config/initializers/core_ext.rb:1: reopening String can't be compiled; use a helper module"],
                 findings("config/initializers/core_ext.rb" => "class String
  def shout = upcase
end
")
  end

  # ApplicationRecord is abstract and not among the manifest's models, but a
  # patch to it reaches every model.
  def test_application_record_has_a_home_too
    app = Struct.new(:models, :controllers).new([{ "name" => "Post", "source" => { "path" => "app/models/post.rb" } }], [])
    homes = Rutile::Check.homes(app)
    assert_equal "app/models/application_record.rb", homes["ApplicationRecord"]
    assert_equal ["config/initializers/patch.rb:1: reopening ApplicationRecord can't be compiled; use a helper module"],
                 findings({ "config/initializers/patch.rb" => "ApplicationRecord.class_eval { def title = \"x\" }\n" }, homes)
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

  def test_every_way_to_reopen_a_core_class
    ruby = <<~RUBY
      class ::String; end
      module Tools
        class ::String; end
      end
      class String < Object; end
      String.class_eval { def extra = 1 }
    RUBY
    assert_equal [1, 3, 5, 6].map { "lib/core_ext.rb:#{_1}: reopening String can't be compiled; use a helper module" },
                 findings("lib/core_ext.rb" => ruby)
  end
end
