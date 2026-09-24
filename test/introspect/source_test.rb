require "minitest/autorun"
require "minitest/mock"
require "pathname"
require_relative "../../lib/rutile/introspect/source"

# Source only asks Rails for its root; the host test process never loads Rails.
module Rails
  def self.root = Pathname("/srv/blog")
end unless defined?(Rails)

class SourceTest < Minitest::Test
  S = Rutile::Introspect::Source

  def test_app_files_are_relative_to_the_root
    assert_equal({ "path" => "app/models/post.rb", "line" => 3 }, S.location("/srv/blog/app/models/post.rb", 3))
  end

  def test_files_outside_the_app_have_no_location
    assert_nil S.location("/usr/lib/ruby/3.4.0/set.rb", 1)
    assert_nil S.location
  end

  def test_gems_vendored_inside_the_app_are_not_app_code
    vendored = "/srv/blog/vendor/bundle/ruby/3.4.0"
    Gem.stub(:path, [vendored]) do
      assert_nil S.location("#{vendored}/gems/activerecord-8.1.4/lib/active_record/enum.rb", 317)
    end
  end
end
