require "minitest/autorun"
require_relative "../../lib/rutile/introspect/serialize"

class SerializeTest < Minitest::Test
  S = Rutile::Introspect::Serialize

  def test_json_native_values_pass_through
    assert_equal [1, 2.5, "a", true, false, nil], S.value([1, 2.5, "a", true, false, nil])
  end

  def test_symbols_become_strings
    assert_equal "destroy", S.value(:destroy)
  end

  def test_hash_keys_become_sorted_strings
    assert_equal [["a", 1], ["b", "x"]], S.value({ b: :x, a: 1 }).to_a
  end

  def test_regexp_range_and_class_are_tagged
    assert_equal({ "regexp" => "\\A\\d+\\z", "options" => 0 }, S.value(/\A\d+\z/))
    assert_equal({ "range" => [1, 5], "exclude_end" => true }, S.value(1...5))
    assert_equal({ "class" => "String" }, S.value(String))
  end

  def test_infinite_floats_become_strings
    assert_equal "Infinity", S.value(Float::INFINITY)
  end

  def test_unknown_objects_keep_their_class_name
    assert_equal({ "object" => "Object" }, S.value(Object.new))
  end
end
