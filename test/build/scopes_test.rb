require_relative "../build_helper"

class ScopesTest < Minitest::Test
  include BuildHelper

  def test_application_record_scopes_are_generic
    rust = Rutile::Build::ApplicationRecordFile.new(app).to_rust
    assert_includes rust, "use rustonrails::{Model, Relation, Time};"
    assert_rust_includes rust, "pub trait ApplicationRecordScopes { fn created_since(self, time: Time) -> Self; }"
    assert_rust_includes rust, <<~RUST
      impl<M: Model> ApplicationRecordScopes for Relation<M> {
          // app/models/application_record.rb:4
          fn created_since(self, time: Time) -> Self {
              self.where_gte("created_at", time)
          }
      }
    RUST
  end

  def test_model_scopes_and_enum_scopes_share_a_trait
    post = Rutile::Build::ModelFile.new(app, "Post").to_rust
    assert_rust_includes post, <<~RUST
      pub trait PostScopes {
          fn draft(self) -> Self; fn not_draft(self) -> Self; fn not_published(self) -> Self;
          fn published(self) -> Self; fn recent(self) -> Self; fn visible(self) -> Self;
      }
    RUST
    assert_rust_includes post, '// app/models/post.rb:9 fn recent(self) -> Self { self.order_desc("created_at") }'
    assert_rust_includes post, '// app/models/post.rb:10 fn visible(self) -> Self { self.where_eq("status", "published") }'
    assert_rust_includes post, 'fn not_draft(self) -> Self { self.where_not("status", "draft") }'
  end

  # Rails defines draft, not_draft, then the next label's pair, and a later
  # scope replaces an earlier one of the same name.
  def test_a_label_starting_with_not_is_whichever_scope_came_last
    scopes = lambda do |labels|
      app_with do |m|
        post = m["models"].find { _1["name"] == "Post" }
        post["enums"]["status"] = labels.each_with_index.to_h
        post["scopes"] = %w[not_started started not_not_started].map { { "name" => _1, "origin" => "framework", "source" => nil } }
      end
    end
    trait = ->(app) { Rutile::Build::Scopes.for_model(app, Rutile::Build::Uses.new, "Post") }
    later_negation = trait.(scopes.(%w[not_started started]))
    assert_rust_includes later_negation, 'fn not_started(self) -> Self { self.where_not("status", "started") }'
    later_label = trait.(scopes.(%w[started not_started]))
    assert_rust_includes later_label, 'fn not_started(self) -> Self { self.where_eq("status", "not_started") }'
  end

  # A Ruby name that's a Rust keyword becomes a raw identifier.
  def test_a_scope_parameter_named_like_a_keyword
    app = scratch_app({ "app/models/post.rb" => ->(ruby) { ruby.sub("-> { where(status: :published) }", "->(type) { where(status: type) }") } })
    assert_rust_includes Rutile::Build::ModelFile.new(app, "Post").to_rust,
                         'fn visible(self, r#type: String) -> Self { self.where_eq("status", r#type.clone()) }'
  end

  def test_destructured_scope_parameters_are_refused
    app = scratch_app({ "app/models/post.rb" => ->(ruby) { ruby.sub("-> { where(status: :published) }", "->((x, y)) { where(status: x) }") } })
    error = assert_raises(Rutile::Build::Unsupported) { Rutile::Build::ModelFile.new(app, "Post").to_rust }
    assert_equal "app/models/post.rb:10: scope parameters other than plain ones isn't supported yet", error.message
  end

  # `crate` can't be a raw identifier; a reassigned parameter would need `mut`.
  def test_awkward_scope_parameter_names
    crate = scratch_app({ "app/models/post.rb" => ->(ruby) { ruby.sub("-> { where(status: :published) }", "->(crate) { where(status: crate) }") } })
    assert_rust_includes Rutile::Build::ModelFile.new(crate, "Post").to_rust,
                         'fn visible(self, crate_: String) -> Self { self.where_eq("status", crate_.clone()) }'
    again = scratch_app({ "app/models/post.rb" => ->(ruby) { ruby.sub("-> { where(status: :published) }", "->(type) { type = type; where(status: type) }") } })
    error = assert_raises(Rutile::Build::Unsupported) { Rutile::Build::ModelFile.new(again, "Post").to_rust }
    assert_equal "app/models/post.rb:10: assigning to the parameter type isn't supported yet", error.message
  end
end
