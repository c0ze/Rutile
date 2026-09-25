require_relative "../build_helper"
require_relative "../tracker_helper"

# has_many's dependent: options sit where Rails registers them: a
# before_destroy at the association's place in the chain.
class DependentTest < Minitest::Test
  include BuildHelper
  include TrackerHelper

  def user_with(dependent)
    manifest = JSON.parse(JSON.generate(TrackerHelper.manifest))
    user = manifest["models"].find { _1["name"] == "User" }
    user["associations"].find { _1["name"] == "assigned_tasks" }["options"]["dependent"] = dependent
    Rutile::Build::App.new(TrackerHelper::APP, manifest, diagnostics: Rutile::Build::Diagnostics.new)
  end

  def test_nullify_in_chain_order
    assert_rust_includes Rutile::Build::ModelFile.new(tracker, "User").to_rust, <<~RUST
      // has_many :memberships, dependent: :destroy
      .before_destroy(|ctx, user| User::MEMBERSHIPS.destroy_all(ctx, user))
      // has_many :owned_projects, dependent: :destroy
      .before_destroy(|ctx, user| User::OWNED_PROJECTS.destroy_all(ctx, user))
      // has_many :assigned_tasks, dependent: :nullify
      .before_destroy(|ctx, user| User::ASSIGNED_TASKS.nullify_all(ctx, user))
    RUST
  end

  def test_the_other_dependent_options_are_refused
    %w[delete_all restrict_with_error restrict_with_exception destroy_async].each do |dependent|
      app = user_with(dependent)
      rust = Rutile::Build::ModelFile.new(app, "User").to_rust
      assert_includes app.diagnostics.problems, "app/models/user.rb: dependent: :#{dependent} isn't supported yet"
      refute_match(/ASSIGNED_TASKS\.\w+_all/, rust)
    end
  end
end
