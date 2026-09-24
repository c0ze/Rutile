require "minitest/autorun"
require_relative "../../lib/rutile/build"

# Ruby regexps as Rust `regex` patterns that accept the same strings.
class RegexpTest < Minitest::Test
  def rust(source, options = 0) = Rutile::Build::RubyRegexp.to_rust(source, options, "user.rb")

  def test_shorthand_classes_stay_ascii
    assert_equal '\A[0-9]+[a-zA-Z0-9_][ \t\n\x0B\x0C\r][0-9a-fA-F]\z', rust('\A\d+\w\s\h\z')
    assert_equal '[^0-9][^a-zA-Z0-9_]', rust('\D\W')
    assert_equal '[0-9a-zA-Z0-9_.-]', rust('[\d\w.-]')
    assert_equal '(?-u:\b)ab(?-u:\B)', rust('\bab\B')
  end

  def test_the_email_regexp_is_unchanged
    email = '\A[a-zA-Z0-9.!\#$%&\'*+/=?^_`{|}~-]+@[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\z'
    assert_equal email, rust(email)
  end

  def test_line_anchors_and_flags
    assert_equal '(?m)^a$', rust('^a$')
    assert_equal '(?i)abc', rust("abc", 1)
    assert_equal '(?s)a.b', rust("a.b", 4)
    assert_equal '(?s:a.)b', rust('(?m:a.)b')
    assert_equal 'a\n?\z', rust('a\Z')
  end

  def test_what_rust_cannot_do_is_refused
    { 'a(?=b)' => "look-around", 'a(?<!b)' => "look-around", '(a)\1' => "a backreference", 'a++' => "a possessive quantifier",
      '(?>a)' => "an atomic group", '[[:alpha:]]' => "a POSIX bracket", '\G' => '\G' }.each do |source, what|
      error = assert_raises(Rutile::Build::Unsupported, source) { rust(source) }
      assert_equal "user.rb: #{what} in a regexp isn't supported yet", error.message
    end
  end
end
