# has_many :through Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Compile `has_many :through` (the join-model shape: through a `has_many`, sourced from a `belongs_to` on the join model), and the relation calls the tracker makes on it: `find(id)` and `include?(record)`. This is gap group 1 in `docs/gaps.md`, 6 of the tracker's 18 findings.

**Architecture:** RustOnRails gets `HasManyThrough<M, T>`, whose `of(ctx, owner)` returns an ordinary `Relation<T>` carrying an inner join (`INNER JOIN memberships ON projects.id = memberships.project_id WHERE memberships.user_id = $1`, the SQL Rails generates). Every relation method (scopes, `order`, `limit`, `find`, `count`, `load`) works on it unchanged. `Relation::contains` answers `include?` with an `exists?` query, as Rails does on an unloaded relation. Rutile emits the constant from the manifest (the join table and both keys come from the two associations it chains), translates `of`/`find`/`include?`, and refuses what a through relation can't do here: building or creating through it, and `includes` of it.

This runs alongside the cloud branch `tracker-gaps-2a` (validators, dates, dirty conditions, nullify, rescue handlers). It touches association code only, and `docs/gaps.md` and `docs/tracker-check.txt` get merged when both land.

**Tech Stack:** Rust 2024 (RustOnRails), Ruby 3.4.9 + Prism (Rutile).

**Spec:** `docs/gaps.md` group 1; `docs/design.md`.

## Global Constraints

- Only the join-model shape: the `through:` association is a `has_many` on the owner, and the source is a `belongs_to` on the join model. Any other shape (through a `belongs_to` or `has_one`, a source that's a `has_many`, `source_type`, a `dependent:` on the through association) raises `Unsupported`.
- The SQL is Rails': an inner join, no `DISTINCT`. An owner without an id (unsaved) gives an empty relation, as Rails' `none`.
- `include?(nil)` is false, as in Ruby.
- Blog output unchanged; RustOnRails zero warnings; Rutile files under 300 lines.

## Review Focus

1. **Keys the right way round.** `User#projects`: `projects.id = memberships.project_id`, filtered by `memberships.user_id`; `Project#members` (`source: :user`): `users.id = memberships.user_id`, filtered by `memberships.project_id`.
2. **Composes with everything else.** A scope, `where`, `order` and `limit` on a through relation qualify their columns with the target table, so a column the join table shares (`id`, `created_at`) is never ambiguous.
3. **Refused, not miscompiled.** `current_user.projects.new(...)`, `.create!(...)` and `includes(:members)` raise `Unsupported`.

---

### Task 1: HasManyThrough in RustOnRails

**Files:**
- Modify: `../RustOnRails/src/association.rs`, `../RustOnRails/src/relation.rs`, `../RustOnRails/src/lib.rs`
- Test: `../RustOnRails/tests/through_test.rs`

**Interfaces:**
- Produces: `HasManyThrough::<M, T>::new(name: &'static str, join_table: &'static str, owner_key: &'static str, target_key: &'static str)` (a `const fn`), `.of(&self, ctx: &Ctx, owner: Handle<M>) -> Relation<T>`; `Relation::join_through(self, join_table, target_key, owner_key, owner_id: Value) -> Self`; `Relation::contains(&self, ctx: &mut Ctx, record: impl Into<Option<Handle<M>>>) -> Result<bool>`.

- [ ] **Step 1: Write the failing test**

`../RustOnRails/tests/through_test.rs`: inline models over the blog's schema. `Author` (users), `Article` (posts), `Remark` (comments), and `Author::COMMENTED: HasManyThrough<Author, Article> = HasManyThrough::new("commented", "comments", "user_id", "post_id")`. Insert two users, three posts, and comments so that user 1 commented on posts A and B (A twice) and user 2 on C. Then:

- `COMMENTED.of(&ctx, u1).order_asc("title").load` gives A, A, B. That's Rails' join, which repeats A.
- `.where_eq("title", "B")` narrows it to B, which proves the target table qualifies the column.
- `.find(&mut ctx, c_id)` is `RecordNotFound`; `.find(&mut ctx, b_id)` is B.
- `.contains(&mut ctx, b)` is true, `.contains(&mut ctx, c)` is false, `.contains(&mut ctx, None)` is false.
- `.count` is 3.
- For an unsaved author (`ctx.build(Author::new_record())`), `load` is empty.
- `to_sql()` of `COMMENTED.of(&ctx, u1)` equals `SELECT "posts"."id", ... FROM "posts" INNER JOIN "comments" ON "posts"."id" = "comments"."post_id" WHERE "comments"."user_id" = $1`, with the columns as the existing `to_sql` lists them.

- [ ] **Step 2: Run it to verify it fails**

Run: `cd ../RustOnRails && cargo test --test through_test 2>&1 | grep -E '^error' | head -3`
Expected: unresolved `HasManyThrough`.

- [ ] **Step 3: Implement**

`relation.rs`: a field `join: Option<Join>`, where

```rust
/// `has_many :through`'s inner join: the join table, its key to the
/// target, and its key to the owner with the owner's id.
#[derive(Clone)]
struct Join {
    table: &'static str,
    target_key: &'static str,
    owner_key: &'static str,
    owner_id: Value,
}
```

`join_through` sets it. `to_sql` emits ` INNER JOIN "join" ON "target"."id" = "join"."target_key"` after `FROM`, and makes `"join"."owner_key" = $n` the first `WHERE` condition, with the rest joined by `AND` as now. A `Value::Nil` owner id (unsaved owner) makes that condition `1=0`. `contains` looks up the record's id. With no record or no id it's `Ok(false)`; otherwise it's `self.clone().where_eq("id", id).exists(ctx)`.

`association.rs`:

```rust
/// `has_many :projects, through: :memberships`: the owner's rows in the
/// join table, and the targets they point at.
pub struct HasManyThrough<M: 'static, T: 'static> {
    pub name: &'static str,
    pub join_table: &'static str,
    pub owner_key: &'static str,
    pub target_key: &'static str,
    marker: PhantomData<fn() -> (M, T)>,
}

impl<M: Model, T: Model> HasManyThrough<M, T> {
    pub const fn new(name: &'static str, join_table: &'static str, owner_key: &'static str, target_key: &'static str) -> Self {
        Self { name, join_table, owner_key, target_key, marker: PhantomData }
    }

    pub fn of(&self, ctx: &Ctx, owner: Handle<M>) -> Relation<T> {
        let id = ctx[owner].id().map_or(Value::Nil, Value::Int);
        Relation::new().join_through(self.join_table, self.target_key, self.owner_key, id)
    }
}
```

(Follow `HasMany`'s own definition for the marker type and trait bounds; if it declares them differently, match it.) Export `HasManyThrough` from `lib.rs`.

- [ ] **Step 4: Run the tests**

Run: `cd ../RustOnRails && cargo test --workspace 2>&1 | grep -E '^test result' | awk '{s+=$4; f+=$6} END {print s" passed, "f" failed"}'`
Expected: 137 + the new tests pass, zero warnings.

- [ ] **Step 5: Commit**

```bash
cd ../RustOnRails && git add -A src tests && git commit -m "has_many :through: an inner join on Relation, and contains for include?"
```

### Task 2: Rutile compiles it

**Files:**
- Modify: `lib/rutile/build/model_file.rb`, `lib/rutile/build/model_calls.rb`
- Test: `test/build/inherited_test.rb` (the tracker), `test/build/translator_test.rb`

**Interfaces:**
- Consumes: Task 1's API.
- Produces: a `through` code path in `ModelFile#association` and `ModelCalls#association`; `find` and `include?` on relations.

- [ ] **Step 1: Write the failing tests** (append to `InheritedTest`)

```ruby
  def test_through_associations_are_join_constants
    user = Rutile::Build::ModelFile.new(tracker, "User").to_rust
    assert_rust_includes user, 'pub const PROJECTS: HasManyThrough<User, Project> = HasManyThrough::new("projects", "memberships", "user_id", "project_id");'
    project = Rutile::Build::ModelFile.new(tracker, "Project").to_rust
    assert_rust_includes project, 'pub const MEMBERS: HasManyThrough<Project, User> = HasManyThrough::new("members", "memberships", "project_id", "user_id");'
  end

  # set_project: current_user.projects.find(params[:project_id])
  def test_find_through_an_association
    rust, problems = controller("TasksController")
    assert_rust_includes rust, 'User::PROJECTS.of(&req.ctx, ' # then .find(&mut req.ctx, req.params.value("project_id"))?
    assert_rust_includes rust, '.find(&mut req.ctx, req.params.value("project_id"))?'
    refute problems.any? { _1.include?("through") }, problems.join("\n")
  end

  # errors.add(...) unless project.members.include?(assignee)
  def test_include_through_an_association
    rust = Rutile::Build::ModelFile.new(tracker, "Task").to_rust
    assert_rust_includes rust, "Project::MEMBERS.of(ctx, project).contains(ctx, assignee)?"
  end

  def test_building_through_a_through_association_is_refused
    translator = Rutile::Build::Translator.new(tracker, "snippet.rb", Rutile::Build::Uses.new, env: :model, model: "User", self_var: "user")
    %w[projects.new(name:\ "x") projects.create!(name:\ "x") projects.includes(:owner)].each do |ruby|
      error = assert_raises(Rutile::Build::Unsupported, ruby) { translator.body(Prism.parse(ruby).value.statements, :unit) }
      assert_match(/through has_many :projects/, error.message)
    end
  end
```

(The last test's `includes(:owner)` is `includes` on a through relation; refusing it is simplest until preloading through a join exists. The message names the through association.)

- [ ] **Step 2: Run them to verify they fail**

Run: `bundle exec ruby -Itest test/build/inherited_test.rb 2>&1 | tail -1`
Expected: the four new tests fail ("has_many :projects with through isn't supported yet").

- [ ] **Step 3: Implement**

`ModelFile`:
- `through` and `source` join `ASSOCIATION_OPTIONS`.
- `association(assoc)`: when `assoc["options"]["through"]` is set, return `through_constant(assoc)`.

```ruby
      # has_many :through a join model's has_many, sourced from a belongs_to
      # on the join model; any other shape is refused.
      def through_constant(assoc)
        link = @app.association(@name, assoc["options"]["through"])
        source_name = assoc["options"]["source"] || assoc["name"].delete_suffix("s")
        source = link && @app.association(link["class_name"], source_name)
        unless link&.fetch("macro") == "has_many" && !link["options"]["through"] && source&.fetch("macro") == "belongs_to" &&
               (assoc["options"].keys - %w[through source]).empty?
          raise Unsupported, "#{@path}: has_many :#{assoc["name"]} through #{assoc["options"]["through"]} in this shape isn't supported yet"
        end

        @uses.rt("HasManyThrough")
        target = assoc["class_name"]
        @uses.model(target) unless target == @name
        table = @app.model(link["class_name"])["table_name"]
        "// has_many :#{assoc["name"]}, through: :#{link["name"]}\npub const #{Names.constant(assoc["name"])}: " \
          "HasManyThrough<#{@name}, #{target}> = HasManyThrough::new(#{Names.str(assoc["name"])}, #{Names.str(table)}, " \
          "#{Names.str(link["foreign_key"])}, #{Names.str(source["foreign_key"])});"
      end
```

(Singularizing by stripping `s` covers the tracker (`projects` → `project`); use ActiveSupport-free rules only if a test needs more, and otherwise refuse when the source association isn't found, which the `unless` already does.)

`ModelCalls#association`:
- Accept `through`/`source` like the model file does, but let the model file's shape check be the authority. Call a shared class method `ModelFile.through_parts(app, model, assoc)`, which returns `[link, source]` or `nil`, so both places refuse the same way. Refactor `through_constant` onto it.
- A through association returns `Code["#{const}.of(#{ctx_ref}, #{owner})", T.relation(target), :read, hint: name, through: name]` with no `via`, so `new`/`build`/`create` through it find no owner and are refused.
- `on_relation`: `"new"`, `"build"`, `"create"`, `"create!"`, and `"includes"` on a relation with `extra[:through]` raise `Unsupported` "through has_many :#{name}". `"find"` becomes `Code["#{receiver.rust}.find(#{ctx_mut}, #{owned(id)})?", T.record(model), :write, hint: Names.snake(model)]`, with the id settled first like `on_class#find`. `"include?"` becomes `Code["#{receiver.rust}.contains(#{ctx_mut}, #{record.rust})?", T::BOOL, :write]`, where the argument must be the relation's model or a nilable of it, and is settled first.

- [ ] **Step 4: Run the tests**

Run: `bundle exec rake test 2>&1 | grep 'runs,'`
Expected: 0 failures, 0 errors.

- [ ] **Step 5: Commit**

```bash
git add lib test && git commit -m "rutile build: has_many :through, find and include? on relations"
```

### Task 3: The tracker and the blog

- [ ] Blog: `bundle exec rake example:check` → `no problems`; `example:build` → no diff; RustOnRails `cargo test --workspace` green; `example:verify` 17/17.
- [ ] Tracker: `EXAMPLE=tracker bundle exec rake example:check`, then save the report lines to `docs/tracker-check.txt`. The six through findings are gone; newly exposed ones appear, since `set_project` and `set_task` now compile further.
- [ ] `docs/gaps.md`: move group 1 to Done, and recount and re-rank from the new report (the cloud branch changes this file too; it gets merged when that branch lands).
- [ ] Commit: `git add docs && git commit -m "The tracker after has_many :through"`.

---

## Self-review

- Spec: gaps.md group 1 (6 findings), plus the `find`/`include?` calls it hid.
- Types: `HasManyThrough::new(name, join_table, owner_key, target_key)` in Tasks 1 and 2 match. `contains(ctx, impl Into<Option<Handle>>)` is used with a handle or an `Option`.
- Review Focus: 1 → `test_through_associations_are_join_constants` and the runtime SQL test; 2 → the `where_eq("title")` narrowing in `through_test`; 3 → `test_building_through_a_through_association_is_refused`.
