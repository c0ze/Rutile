require "fileutils"
require_relative "../introspect_helper"
require_relative "../tracker_helper"

# Introspection of an edited copy of the tracker: what a model replaces of
# Active Record's, stacked and wrapped normalizers, and enum options.
class OverridesTest < Minitest::Test
  EDITS = {
    "app/models/task.rb" => lambda do |ruby|
      ruby.sub("  private\n", "  def destroy = update(completed_at: Time.current)\n\n  private\n\n  def readonly? = false\n")
          .sub("validate: true\n  enum :priority", "validate: true, instance_methods: false\n  enum :priority")
    end,
    "app/models/user.rb" => lambda do |ruby|
      ruby.sub("  validates :name", "  normalizes :email, with: ->(email) { email.squish }\n  encrypts :name\n\n" \
                                    "  def self.generate_unique_secure_token(length: 24) = \"tok\"\n\n  validates :name")
    end
  }.freeze

  def self.manifest
    @manifest ||= begin
      root = Dir.mktmpdir("tracker")
      FileUtils.cp_r(Dir.glob(File.join(TrackerHelper::APP, "*")).reject { _1.end_with?("/tmp", "/log") }, root)
      EDITS.each { |path, edit| File.write(File.join(root, path), edit.(File.read(File.join(root, path)))) }
      out = File.join(root, "tmp/manifest.json")
      Rutile::Introspect.run(app_dir: root, env: "test", out:, vars: IntrospectHelper::CLEAN_ENV)
      JSON.parse(File.read(out))
    end
  end

  def model(name) = OverridesTest.manifest["models"].find { _1["name"] == name }

  def test_methods_replacing_active_records_are_listed_with_their_source
    assert_equal [{ "name" => "destroy", "source" => { "path" => "app/models/task.rb", "line" => 21 } },
                  { "name" => "readonly?", "source" => { "path" => "app/models/task.rb", "line" => 25 } }],
                 model("Task")["overrides"]
    assert_equal [{ "name" => "self.generate_unique_secure_token", "source" => { "path" => "app/models/user.rb", "line" => 13 } }],
                 model("User")["overrides"]
  end

  # Each `normalizes` wraps the type again, the first one innermost; an
  # `encrypts` around them is passed through.
  def test_every_normalizer_in_the_order_they_run
    assert_equal [{ "proc" => { "path" => "app/models/user.rb", "line" => 8 } },
                  { "proc" => { "path" => "app/models/user.rb", "line" => 10 } }],
                 model("User")["normalizations"]["email"].map { _1["with"] }
  end

  def test_enum_methods_follow_instance_methods_false
    assert_equal %w[high! high? low! low? normal! normal?], model("Task")["enum_methods"]
  end
end
