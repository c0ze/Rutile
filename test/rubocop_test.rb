require "json"
require "minitest/autorun"
require "tmpdir"
require "rubocop"
require_relative "../lib/rutile"

# The subset rules as a RuboCop plugin: the same findings as `rutile check`,
# on the exact code, in the editor.
class RubocopTest < Minitest::Test
  RUBY = <<~RUBY.freeze
    class Thing
      @@count = 0

      def assign(field, value)
        send("\#{field}=", value) # é
      end

      def method_missing(name, *args) = super
    end
  RUBY

  def offenses(plugin)
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, ".rubocop.yml"), <<~YAML)
        plugins:
          - #{plugin}
        AllCops:
          TargetRubyVersion: 3.4
          SuggestExtensions: false
      YAML
      FileUtils.mkdir_p(File.join(dir, "app/models"))
      File.write(File.join(dir, "app/models/thing.rb"), RUBY)
      File.write(File.join(dir, "outside.rb"), "eval('1')\n")
      out = File.join(dir, "out.json")
      Dir.chdir(dir) { RuboCop::CLI.new.run(["--only", "Rutile/Subset", "--format", "json", "--out", out, "."]) }
      JSON.parse(File.read(out, encoding: Encoding::UTF_8))["files"].flat_map do |file|
        path = file["path"].delete_prefix(File.realpath(dir) + "/").delete_prefix(dir + "/")
        file["offenses"].map { [path, _1["cop_name"], _1.dig("location", "start_line"), _1.dig("location", "start_column"), _1["message"]] }
      end
    end
  end

  def test_the_plugin_reports_what_check_rejects
    cop = "Rutile/Subset"
    assert_equal [["app/models/thing.rb", cop, 2, 3, "the class variable @@count can't be compiled; use a constant, Rails.cache, or the database."],
                  ["app/models/thing.rb", cop, 5, 5, "send with a computed name can't be compiled; use a case over the known names."],
                  ["app/models/thing.rb", cop, 8, 3, "def method_missing can't be compiled; use explicit methods."]],
                 offenses("rutile")
  end

  # Only app/ and lib/, as `rutile check` scans; the explicit form too.
  def test_the_explicit_form
    assert_equal 3, offenses("rutile:\n      require_path: rutile/rubocop").size
  end

  def test_findings_carry_byte_offsets
    source = "x = 'é'\n$g = 1\n"
    message, start, finish = Rutile::Check::Rules.findings(source).first
    assert_equal "assigning the global $g can't be compiled; use a constant, Rails.cache, or the database", message
    assert_equal "$g = 1", source.byteslice(start...finish)
  end
end
