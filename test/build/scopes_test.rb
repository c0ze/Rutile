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

  # A Ruby name that's a Rust keyword becomes a raw identifier.
  def test_a_scope_parameter_named_like_a_keyword
    app = scratch_app({ "app/models/post.rb" => ->(ruby) { ruby.sub("-> { where(status: :published) }", "->(type) { where(status: type) }") } })
    assert_rust_includes Rutile::Build::ModelFile.new(app, "Post").to_rust,
                         'fn visible(self, r#type: String) -> Self { self.where_eq("status", r#type.clone()) }'
  end
end
