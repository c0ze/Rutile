require_relative "../build_helper"
require_relative "../tracker_helper"

# `normalizes` and `has_secure_token`, compiled from what introspection
# records about the tracker's User.
class ModelMacrosBuildTest < Minitest::Test
  include BuildHelper
  include TrackerHelper

  def rust(app = tracker) = Rutile::Build::ModelFile.new(app, "User").to_rust

  def user_with
    manifest = JSON.parse(JSON.generate(TrackerHelper.manifest))
    yield manifest["models"].find { _1["name"] == "User" }
    Rutile::Build::App.new(TrackerHelper::APP, manifest, diagnostics: Rutile::Build::Diagnostics.new)
  end

  def test_a_normalizer_is_the_apps_lambda
    assert_rust_includes rust, <<~RUST
      // normalizes :email (app/models/user.rb:8)
      pub fn normalize_email(email: String) -> String {
          email.strip().downcase()
      }
    RUST
    assert_rust_includes rust, <<~RUST
      Behavior::<User>::new()
          // normalizes :email
          .normalizes("email", User::normalize_email)
          // has_secure_token :api_token
          .has_secure_token("api_token", 24)
          // validates :name, presence
    RUST
  end

  def test_a_token_on_create_is_a_hook_in_its_slot
    app = user_with do |user|
      token = user["callbacks"].delete("initialize").first.merge("kind" => "before")
      user["callbacks"]["create"].unshift(token)
    end
    assert_rust_includes rust(app), <<~RUST
      // has_secure_token :api_token, on: :create
      .before_create(|ctx, user| ctx.fill_secure_token(user, "api_token", 24))
    RUST
    refute_includes rust(app), ".has_secure_token("
  end

  def test_normalizations_rust_cant_keep_are_refused
    { { "apply_to_nil" => true } => "normalizes :email with apply_to_nil",
      { "with" => { "proc" => nil } } => "normalizes :email with a normalizer that isn't a lambda in the app",
      { "with" => { "object" => "EmailNormalizer" } } => "normalizes :email with a normalizer that isn't a lambda in the app" }
      .each do |change, message|
        app = user_with { _1["normalizations"]["email"].merge!(change) }
        refute_includes rust(app), "normalize_email"
        assert_equal ["app/models/user.rb: #{message} isn't supported yet"], app.diagnostics.problems
      end
    app = user_with { _1["normalizations"] = { "created_at" => _1["normalizations"]["email"] } }
    rust(app)
    assert_equal ["app/models/user.rb: normalizes on the time column created_at isn't supported yet"], app.diagnostics.problems
  end

  def test_a_normalizer_must_give_back_a_string
    app = scratch_app({ "app/models/user.rb" => ->(ruby) { ruby.sub("email.strip.downcase", "email.present?") } },
                      diagnostics: Rutile::Build::Diagnostics.new, manifest: TrackerHelper.manifest, from: TrackerHelper::APP)
    rust(app)
    assert_equal ["app/models/user.rb:8: a normalizer returning bool isn't supported yet"], app.diagnostics.problems
  end

  def test_fallible_code_is_found_outside_string_literals
    assert Rutile::Build::ModelMacros.fallible?(["value.to_str()?"])
    refute Rutile::Build::ModelMacros.fallible?(['format!("what? {}", x)', 'r#"a?"#.to_string()'])
  end

  def callback(ruby)
    translator = Rutile::Build::Translator.new(tracker, "snippet.rb", Rutile::Build::Uses.new, env: :model, model: "User",
                                                                                              self_var: "user")
    translator.body(Prism.parse(ruby).value.statements, :unit).first.join("\n")
  end

  # The attribute writer normalizes; so does code writing the field.
  def test_writes_to_a_normalized_attribute_normalize
    assert_rust_includes callback('self.email = " Ann@Example.com"'),
                         'ctx[user].email = Some(User::normalize_email(" Ann@Example.com".to_string()));'
    assert_rust_includes callback("self.email = name"), "let name = ctx[user].name.clone(); ctx[user].email = name.map(User::normalize_email);"
    assert_rust_includes callback("self.email ||= name.to_s"),
                         "if ctx[user].email.is_none() { let name = ctx[user].name.clone().unwrap_or_default(); " \
                         "ctx[user].email = Some(User::normalize_email(name)); }"
    assert_rust_includes callback('self.name = " x "'), 'ctx[user].name = Some(" x ".to_string());'
  end
end
