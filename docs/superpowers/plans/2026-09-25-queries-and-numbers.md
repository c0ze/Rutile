# Queries and Numbers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Compile the tracker's pagination, its two-hop `joins` and its SQL-fragment search scope. That covers gap groups 3 (the query API) and 5 (numbers, constants and small helpers) in `docs/gaps.md`.

**Architecture:** Each Ruby construct gets a runtime piece in RustOnRails and a translation in Rutile:
- **Runtime (RustOnRails):** `Relation` gains `offset`, `joins` along associations, `where_on` for a joined table's columns, and `where_sql` for fragments with `?` binds. `sanitize_sql_like`, `Value::to_i`, `Value::to_str` and `Params::fetch` follow Ruby.
- **Translation (Rutile):** class-body constants become Rust `const`s. `+ - *` compile to Rust operators in crates built with overflow checks. The query methods move into their own module.

**Tech Stack:** Ruby 3.4 (Prism, minitest) for Rutile; Rust 2024 with the `postgres` crate for RustOnRails.

**Spec:** `docs/gaps.md` (groups 3 and 5) and `docs/design.md` (the type table: `Integer` is `i64` with checked arithmetic; "fail loudly instead of wrapping").

## Global Constraints

- Keep Ruby's meaning or refuse with `Unsupported` naming `path:line`.
- Rutile files stay under 300 lines.
- RustOnRails and generated code build with zero warnings.
- Blog regression after every Rutile task:
  - `bundle exec rake example:check` prints `no problems`.
  - `bundle exec rake example:build` leaves `git -C ../RustOnRails status --short examples` empty.
  - `bundle exec rake example:verify` passes 17/17.
- Work on branch `tracker-gaps-3` in both repos. Rutile's tests run with `bundle exec rake test`; RustOnRails' with `cargo test --workspace`.
- Integer overflow never wraps. Generated crates build with `overflow-checks = true` in release too, so an overflow panics, and the server turns a panic into a 500.

## Review Focus

1. **Pagination input from strangers.** `?page=0`, `-3`, `abc`, `2abc`, `1_0` and an empty value give pages 1, 1, 1, 2, 10 and 1, as `[params.fetch(:page, 1).to_i, 1].max` does. A page past `i64` is a 500, never a wrapped number. Tests: Task 2 `test_to_i_follows_ruby` and `test_to_i_fails_where_ruby_cant_fit_an_i64`; Task 4 `test_page_from_params_like_rails`.
2. **Search input with LIKE wildcards.** `q=50%` finds "50% off" and not "500 off"; `q=a_b` doesn't match "axb"; a backslash matches itself. Test: Task 1 `test_sanitize_sql_like_matches_the_string_itself`.
3. **Columns a join makes ambiguous.** Filters, `order`, `find` and `count` on a joined relation name the model's table, so `id`, `user_id` and `created_at`, which the joined tables share, never become ambiguous. Test: Task 1 `test_joins_follow_associations_like_rails` (a joined `find`, `count` and `order_asc("id")`).
4. **Overflow in release builds.** `overflow-checks` is on in the RustOnRails workspace and in every `Cargo.toml` Rutile writes. Tests: Task 2 `test_release_builds_check_overflow`; Task 4 `test_generated_crates_check_integer_overflow`.
5. **Constants resolved as Ruby resolves them.** A controller method sees its own class's constant before ApplicationController's. An ApplicationController helper sees only its own. The same name meaning two things in one generated file is refused. Tests: Task 3 `test_a_subclass_constant_hides_application_controllers` and `test_a_name_meaning_two_things_in_one_file_is_refused`.

---

### Task 1: RustOnRails — offset, joins, where_on, where_sql, sanitize_sql_like

**Files:**
- Modify: `RustOnRails/src/relation.rs`
- Modify: `RustOnRails/src/association.rs` (the `Joinable` impls)
- Modify: `RustOnRails/src/lib.rs` (exports)
- Test: `RustOnRails/tests/query_test.rs` (new)

**Interfaces:**
- Produces:
  - `Relation::offset(self, n: i64) -> Self`
  - `Relation::joins(self, association: &impl Joinable) -> Self`
  - `Relation::where_on::<J: Model>(self, column: &str, value: impl Into<Value>) -> Self`
  - `Relation::where_sql(self, sql: &'static str, binds: Vec<Value>) -> Self`
  - `pub fn sanitize_sql_like(string: &str) -> String`
  - `pub trait Joinable { fn inner_join(&self) -> InnerJoin; }`, implemented for `BelongsTo<M, T>` and `HasMany<M, T>`
  - `lib.rs` exports `Joinable`, `InnerJoin` and `sanitize_sql_like`

- [ ] **Step 1: Branch both repos**

```bash
git -C ~/projects/Rutile checkout -b tracker-gaps-3
git -C ~/projects/RustOnRails checkout -b tracker-gaps-3
```

- [ ] **Step 2: Write the failing tests**

Create `RustOnRails/tests/query_test.rs`:

```rust
mod support;

use rustonrails::{BelongsTo, HasMany, Model, Record, Time, model, now, sanitize_sql_like};

model! {
    pub struct Author in "users" { id: i64, name: String, email: String, created_at: Time, updated_at: Time }
}

model! {
    pub struct Article in "posts" {
        id: i64, user_id: i64, title: String, body: String, status: i64 = 0, published_at: Time,
        comments_count: i64 = 0, created_at: Time, updated_at: Time,
    }
}

model! {
    pub struct Remark in "comments" { id: i64, post_id: i64, user_id: i64, body: String, created_at: Time, updated_at: Time }
}

impl Article {
    // belongs_to :user
    pub const AUTHOR: BelongsTo<Article, Author> = BelongsTo::new("user", "user_id");
}

impl Author {
    // has_many :comments
    pub const REMARKS: HasMany<Author, Remark> = HasMany::new("comments", "user_id", None);
}

impl Model for Author {
    fn behavior() -> &'static rustonrails::Behavior<Self> {
        static B: std::sync::LazyLock<rustonrails::Behavior<Author>> = std::sync::LazyLock::new(rustonrails::Behavior::new);
        &B
    }
}
impl Model for Article {
    fn behavior() -> &'static rustonrails::Behavior<Self> {
        static B: std::sync::LazyLock<rustonrails::Behavior<Article>> = std::sync::LazyLock::new(rustonrails::Behavior::new);
        &B
    }
}
impl Model for Remark {
    fn behavior() -> &'static rustonrails::Behavior<Self> {
        static B: std::sync::LazyLock<rustonrails::Behavior<Remark>> = std::sync::LazyLock::new(rustonrails::Behavior::new);
        &B
    }
}

fn author(ctx: &mut rustonrails::Ctx, name: &str) -> i64 {
    let record = Author { name: Some(name.into()), email: Some(format!("{name}@example.com")), created_at: Some(now()), updated_at: Some(now()), ..Author::default() };
    Author::insert(ctx, record).unwrap()
}

fn article(ctx: &mut rustonrails::Ctx, user_id: i64, title: &str) -> i64 {
    let record = Article {
        user_id: Some(user_id), title: Some(title.into()), body: Some("b".into()), status: Some(0), comments_count: Some(0),
        created_at: Some(now()), updated_at: Some(now()), ..Article::default()
    };
    Article::insert(ctx, record).unwrap()
}

fn remark(ctx: &mut rustonrails::Ctx, user_id: i64, post_id: i64, body: &str) {
    let record = Remark { post_id: Some(post_id), user_id: Some(user_id), body: Some(body.into()), created_at: Some(now()), updated_at: Some(now()), ..Remark::default() };
    Remark::insert(ctx, record).unwrap();
}

/// `Article.joins(user: :comments).where(comments: { body: "hi" })`: the
/// SQL Rails writes, duplicates and all, every column qualified.
#[test]
fn test_joins_follow_associations_like_rails() {
    let mut ctx = support::ctx();
    let (ann, bob) = (author(&mut ctx, "ann"), author(&mut ctx, "bob"));
    let (a, b, c) = (article(&mut ctx, ann, "A"), article(&mut ctx, ann, "B"), article(&mut ctx, bob, "C"));
    remark(&mut ctx, ann, c, "hi");
    remark(&mut ctx, ann, c, "hi");
    remark(&mut ctx, bob, a, "no");
    let joined = Article::all().joins(&Article::AUTHOR).joins(&Author::REMARKS).where_on::<Remark>("body", "hi");

    let titles: Vec<String> =
        joined.clone().order_asc("title").load(&mut ctx).unwrap().into_iter().map(|h| ctx[h].title.clone().unwrap()).collect();
    assert_eq!(vec!["A", "A", "B", "B"], titles);
    assert_eq!(4, joined.count(&mut ctx).unwrap());
    let found = joined.find(&mut ctx, b).unwrap();
    assert_eq!(Some(b), ctx[found].id);
    assert!(joined.find(&mut ctx, c).is_err());
    let (sql, _) = joined.order_asc("id").to_sql();
    let expected = r#"FROM "posts" INNER JOIN "users" ON "users"."id" = "posts"."user_id" INNER JOIN "comments" ON "comments"."user_id" = "users"."id" WHERE "comments"."body" = $1 ORDER BY "posts"."id" ASC"#;
    assert!(sql.contains(expected), "{sql}");
}

/// A joined column's value is cast by its own model: a param string finds
/// an integer key, as Rails' type casting does.
#[test]
fn test_where_on_casts_by_the_joined_model() {
    let mut ctx = support::ctx();
    let ann = author(&mut ctx, "ann");
    let a = article(&mut ctx, ann, "A");
    remark(&mut ctx, ann, a, "hi");
    let found = Author::all().joins(&Author::REMARKS).where_on::<Remark>("post_id", a.to_string()).load(&mut ctx).unwrap();
    assert_eq!(vec![Some(ann)], found.into_iter().map(|h| ctx[h].id).collect::<Vec<_>>());
}

/// `offset` skips rows after the order, and `include?` on an offset
/// relation looks in its rows, as Rails does.
#[test]
fn test_offset_skips_rows() {
    let mut ctx = support::ctx();
    let ann = author(&mut ctx, "ann");
    let ids: Vec<i64> = ["A", "B", "C"].iter().map(|t| article(&mut ctx, ann, t)).collect();
    let second = Article::all().order_asc("id").offset(1).limit(1);
    let loaded = second.load(&mut ctx).unwrap();
    assert_eq!(vec![Some(ids[1])], loaded.iter().map(|h| ctx[*h].id).collect::<Vec<_>>());
    let (first, third) = (Article::find(&mut ctx, ids[0]).unwrap(), Article::find(&mut ctx, ids[2]).unwrap());
    assert!(!second.contains(&mut ctx, first).unwrap());
    assert!(Article::all().order_asc("id").offset(1).contains(&mut ctx, third).unwrap());
    assert!(!Article::all().order_asc("id").offset(3).contains(&mut ctx, third).unwrap());
    assert!(second.to_sql().0.ends_with("LIMIT 1 OFFSET 1"));
}

/// `where("title ILIKE ? AND body = ?", ...)`: parenthesized as Rails
/// writes it, its binds numbered after the conditions before it.
#[test]
fn test_a_sql_fragment_binds_in_order() {
    let mut ctx = support::ctx();
    let ann = author(&mut ctx, "ann");
    let notes = article(&mut ctx, ann, "Draft notes");
    article(&mut ctx, ann, "Other");
    let relation = Article::all().where_eq("status", 0).where_sql("title ILIKE ? AND body = ?", vec!["%notes".into(), "b".into()]);
    let (sql, _) = relation.to_sql();
    assert!(sql.contains(r#"WHERE "posts"."status" = $1 AND (title ILIKE $2 AND body = $3)"#), "{sql}");
    let found = relation.load(&mut ctx).unwrap();
    assert_eq!(vec![Some(notes)], found.into_iter().map(|h| ctx[h].id).collect::<Vec<_>>());
}

/// Rails' sanitize_sql_like: a search for "50%" finds "50% off" only.
#[test]
fn test_sanitize_sql_like_matches_the_string_itself() {
    assert_eq!(r"50\%\_off\\", sanitize_sql_like(r"50%_off\"));
    let mut ctx = support::ctx();
    let ann = author(&mut ctx, "ann");
    let titles = ["50% off", "500 off", "a_b", "axb", r"back\slash"];
    let ids: Vec<i64> = titles.iter().map(|t| article(&mut ctx, ann, t)).collect();
    let search = |ctx: &mut rustonrails::Ctx, q: &str| -> Vec<i64> {
        let pattern = format!("%{}%", sanitize_sql_like(q));
        let found = Article::all().where_sql("title ILIKE ?", vec![pattern.into()]).order_asc("id").load(ctx).unwrap();
        found.into_iter().map(|h| ctx[h].id.unwrap()).collect()
    };
    assert_eq!(vec![ids[0]], search(&mut ctx, "50%"));
    assert_eq!(vec![ids[2]], search(&mut ctx, "a_b"));
    assert_eq!(vec![ids[4]], search(&mut ctx, r"k\s"));
}
```

- [ ] **Step 3: Run the tests to watch them fail**

Run: `cargo test --test query_test 2>&1 | tail -5`
Expected: compile errors. `sanitize_sql_like` isn't in `rustonrails`, and `joins`, `where_on`, `offset` and `where_sql` aren't on `Relation`.

- [ ] **Step 4: Implement**

In `src/relation.rs`, after the `Join` struct, add the join type and the trait:

```rust
/// `joins(:project)`: `INNER JOIN table ON table.column = other.other_column`,
/// the keys of one association.
#[derive(Clone, Copy, Debug)]
pub struct InnerJoin {
    pub(crate) table: &'static str,
    pub(crate) column: &'static str,
    pub(crate) other: &'static str,
    pub(crate) other_column: &'static str,
}

/// An association `joins` can follow.
pub trait Joinable {
    fn inner_join(&self) -> InnerJoin;
}
```

Add two variants to `Filter`:

```rust
    /// `where(memberships: { user_id: 1 })`: a joined table's column, the
    /// value already cast by that table's model.
    EqOn(&'static str, String, Value),
    /// `where("title ILIKE ?", pattern)`
    Sql(&'static str, Vec<Value>),
```

Give `Relation` two fields after `join`, `joins: Vec<InnerJoin>` and `offset: Option<i64>`. Add them to `Clone` (`joins: self.joins.clone()`, `offset: self.offset`) and to `Default` (`joins: Vec::new()`, `offset: None`).

Add the methods after `limit`:

```rust
    /// `offset(n)`: skips `n` rows after the order.
    pub fn offset(mut self, n: i64) -> Self {
        self.offset = Some(n);
        self
    }

    /// `joins(:project)`; `joins(project: :memberships)` is two calls.
    pub fn joins(mut self, association: &impl Joinable) -> Self {
        self.joins.push(association.inner_join());
        self
    }

    /// `where(memberships: { user_id: 1 })`: a column of a joined table,
    /// cast by that table's model.
    pub fn where_on<J: Model>(mut self, column: &str, value: impl Into<Value>) -> Self {
        let value = J::behavior().to_database(column, J::cast_query(column, value.into()));
        self.filters.push(Filter::EqOn(J::TABLE, column.to_string(), value));
        self
    }

    /// `where("title ILIKE ?", pattern)`: a SQL fragment, parenthesized as
    /// Rails does, each `?` bound in order. Rutile counts them when it
    /// compiles the call.
    pub fn where_sql(mut self, sql: &'static str, binds: Vec<Value>) -> Self {
        assert_eq!(sql.matches('?').count(), binds.len(), "`{sql}` has a different number of binds");
        self.filters.push(Filter::Sql(sql, binds));
        self
    }
```

In `to_sql`, after the `if let Some(join) = &self.join { ... }` block, add:

```rust
        for join in &self.joins {
            let joined = quote(join.table);
            sql.push_str(&format!(
                " INNER JOIN {joined} ON {joined}.{} = {}.{}",
                quote(join.column),
                quote(join.other),
                quote(join.other_column)
            ));
        }
```

In the filter loop's `match filter`, before `Filter::Eq(c, v) => (c, "=", v),`, add:

```rust
                Filter::EqOn(joined, column, value) => {
                    let target = format!("{}.{}", quote(joined), quote(column));
                    if value.is_nil() {
                        sql.push_str(&format!("{target} IS NULL"));
                    } else {
                        params.push(value.clone());
                        sql.push_str(&format!("{target} = ${}", params.len()));
                    }
                    continue;
                }
                Filter::Sql(fragment, binds) => {
                    let mut parts = fragment.split('?');
                    sql.push('(');
                    sql.push_str(parts.next().unwrap_or_default());
                    for (part, bind) in parts.zip(binds) {
                        params.push(bind.clone());
                        sql.push_str(&format!("${}{part}", params.len()));
                    }
                    sql.push(')');
                    continue;
                }
```

After the `LIMIT` block:

```rust
        if let Some(n) = self.offset {
            sql.push_str(&format!(" OFFSET {n}"));
        }
```

In `contains`, change the condition to `if self.limit.is_some() || self.offset.is_some() {`. Change the comment above it to: "Like Rails, a relation with a limit or offset is loaded and searched: filtering by the id first would change which rows they keep."

Add `sanitize_sql_like` at the end of `relation.rs`:

```rust
/// Rails' `sanitize_sql_like` with its default escape character: each
/// backslash doubled, then one before each `%` and `_`, so the string
/// matches itself inside a LIKE pattern.
pub fn sanitize_sql_like(string: &str) -> String {
    let mut out = String::with_capacity(string.len());
    for c in string.chars() {
        match c {
            '\\' => out.push_str(r"\\"),
            '%' | '_' => {
                out.push('\\');
                out.push(c);
            }
            c => out.push(c),
        }
    }
    out
}
```

In `src/association.rs`, change the import to `use crate::{Ctx, Handle, InnerJoin, Joinable, Model, Relation, Result, Value};` and add after `impl<M: Model, T: Model> Preload<M> for BelongsTo<M, T>`'s block:

```rust
impl<M: Model, T: Model> Joinable for BelongsTo<M, T> {
    /// From a post, `joins(:user)`: `INNER JOIN users ON users.id = posts.user_id`.
    fn inner_join(&self) -> InnerJoin {
        InnerJoin { table: T::TABLE, column: "id", other: M::TABLE, other_column: self.foreign_key }
    }
}
```

and after `HasMany`'s `impl` block:

```rust
impl<M: Model, T: Model> Joinable for HasMany<M, T> {
    /// From a post, `joins(:comments)`: `INNER JOIN comments ON comments.post_id = posts.id`.
    fn inner_join(&self) -> InnerJoin {
        InnerJoin { table: T::TABLE, column: self.foreign_key, other: M::TABLE, other_column: "id" }
    }
}
```

In `src/lib.rs`, change `pub use relation::Relation;` to `pub use relation::{InnerJoin, Joinable, Relation, sanitize_sql_like};`.

- [ ] **Step 5: Run the tests to watch them pass**

Run: `cargo test --test query_test 2>&1 | grep -E 'test result|panicked|^warning'`
Expected: `test result: ok. 5 passed`, and no warnings.

- [ ] **Step 6: Run the workspace**

Run: `cargo test --workspace 2>&1 | grep -E '^test result|^warning' | awk '{print}'`
Expected: every result `ok`, 145 passed in total (140 + 5), no `warning` lines.

- [ ] **Step 7: Commit**

```bash
cd ~/projects/RustOnRails && git add src/relation.rs src/association.rs src/lib.rs tests/query_test.rs && git commit -m "Relation: offset, joins along associations, where_on, where_sql; sanitize_sql_like"
```

---

### Task 2: RustOnRails — to_i, to_str, params.fetch, overflow checks

**Files:**
- Modify: `RustOnRails/src/value.rs`
- Modify: `RustOnRails/src/error.rs`
- Modify: `RustOnRails/src/http/params.rs`
- Modify: `RustOnRails/Cargo.toml`
- Test: `RustOnRails/tests/value_test.rs`, `RustOnRails/tests/params_test.rs`

**Interfaces:**
- Produces:
  - `Value::to_i(&self) -> Result<i64>`
  - `Value::to_str(&self) -> Result<String>`
  - `Params::fetch(&self, key: &str, default: impl Into<Value>) -> Value`
  - `Error::NoMethod { what: &'static str, value: Value }`
  - `Error::Overflow { value: String }`

- [ ] **Step 1: Write the failing tests**

In `tests/value_test.rs`, change the import to `use rustonrails::{Error, FromValue, Time, Value, now};` and append:

```rust
// Checked against Ruby 3.4's String#to_i, Float#to_i and nil.to_i.
#[test]
fn test_to_i_follows_ruby() {
    let cases = [
        ("42abc", 42), ("  -12", -12), ("+5", 5), ("1_000", 1000), ("1__0", 1), ("_1", 0), ("abc", 0), ("", 0),
        ("012", 12), ("0x1A", 0), ("-_1", 0), ("1_", 1), ("\t\n7", 7), ("2abc", 2), ("0", 0),
    ];
    for (text, expected) in cases {
        assert_eq!(expected, Value::from(text).to_i().unwrap(), "{text:?}");
    }
    assert_eq!(0, Value::Nil.to_i().unwrap());
    assert_eq!(7, Value::Int(7).to_i().unwrap());
    assert_eq!(2, Value::Float(2.9).to_i().unwrap());
    assert_eq!(-2, Value::Float(-2.9).to_i().unwrap());
    let time: Time = chrono::DateTime::from_timestamp(1_700_000_000, 0).unwrap().naive_utc();
    assert_eq!(1_700_000_000, Value::Time(time).to_i().unwrap());
}

/// Where Ruby would make a Bignum, or has no to_i, this fails.
#[test]
fn test_to_i_fails_where_ruby_cant_fit_an_i64() {
    assert_eq!(i64::MAX, Value::from("9223372036854775807").to_i().unwrap());
    assert!(matches!(Value::from("99999999999999999999").to_i(), Err(Error::Overflow { .. })));
    assert!(matches!(Value::Float(1e20).to_i(), Err(Error::Overflow { .. })));
    assert!(matches!(Value::Float(f64::NAN).to_i(), Err(Error::Overflow { .. })));
    assert!(matches!(Value::Bool(true).to_i(), Err(Error::NoMethod { what: "to_i", .. })));
}

/// Only a String answers to_str; nil fails as Ruby's NoMethodError on nil does.
#[test]
fn test_to_str_only_for_strings() {
    assert_eq!("q", Value::from("q").to_str().unwrap());
    assert!(matches!(Value::Int(5).to_str(), Err(Error::NoMethod { what: "to_str", .. })));
    assert!(matches!(Value::Nil.to_str(), Err(Error::Nil { what: "to_str" })));
}

/// Ruby promotes an overflowing Integer to a Bignum; generated code must
/// fail instead of wrapping, in release builds too.
#[test]
fn test_release_builds_check_overflow() {
    let manifest = include_str!("../Cargo.toml");
    assert!(manifest.contains("[profile.release]\noverflow-checks = true"), "{manifest}");
}
```

In `tests/params_test.rs`, append:

```rust
/// `params.fetch(:page, 1)`: the value when the key is there (null too),
/// the default when it isn't.
#[test]
fn test_fetch_falls_back_only_when_absent() {
    let params = Params::new(map(json!({"page": "3", "none": null})), map(json!({})));
    assert_eq!(Value::from("3"), params.fetch("page", 1));
    assert_eq!(Value::Int(1), params.fetch("missing", 1));
    assert_eq!(Value::Nil, params.fetch("none", 1));
}
```

- [ ] **Step 2: Run the tests to watch them fail**

Run: `cargo test --test value_test --test params_test 2>&1 | tail -5`
Expected: compile errors. There's no `to_i`, `to_str`, `fetch` or `Error::Overflow`.

- [ ] **Step 3: Implement**

In `src/error.rs`, add two variants after `Nil`:

```rust
    /// A method the value's class doesn't have, Ruby's `NoMethodError`.
    NoMethod { what: &'static str, value: Value },
    /// An Integer Ruby would promote to a Bignum.
    Overflow { value: String },
```

Add their `Display` arms after `Error::Nil`'s:

```rust
            Error::NoMethod { what, value } => write!(f, "undefined method '{what}' for {value:?}"),
            Error::Overflow { value } => write!(f, "{value} doesn't fit in a 64-bit integer"),
```

(`error_response` maps anything it doesn't name to 500, which is what Rails does with these exceptions.)

In `src/value.rs`, add these to `impl Value` after `to_ruby_string`, and add `use crate::{Error, Result};` at the top:

```rust
    /// Ruby's `to_i`: nil is 0, a Float truncates, a Time is its epoch
    /// seconds, and a String reads its leading integer ("42abc" is 42,
    /// "abc" is 0). Where Ruby would make a Bignum this fails, and true and
    /// false have no `to_i`.
    pub fn to_i(&self) -> Result<i64> {
        match self {
            Value::Nil => Ok(0),
            Value::Int(i) => Ok(*i),
            Value::Float(f) => {
                let whole = f.trunc();
                // i64::MAX as f64 rounds up to 2^63, which doesn't fit.
                if (-9_223_372_036_854_775_808.0..9_223_372_036_854_775_808.0).contains(&whole) {
                    Ok(whole as i64)
                } else {
                    Err(Error::Overflow { value: f.to_string() })
                }
            }
            Value::Str(s) => string_to_i(s),
            Value::Time(t) => Ok(t.and_utc().timestamp()),
            Value::Bool(_) => Err(Error::NoMethod { what: "to_i", value: self.clone() }),
        }
    }

    /// `to_str`: only a String has it, so a value that must be one fails
    /// the way the String method it reaches would in Ruby.
    pub fn to_str(&self) -> Result<String> {
        match self {
            Value::Str(s) => Ok(s.clone()),
            Value::Nil => Err(Error::Nil { what: "to_str" }),
            other => Err(Error::NoMethod { what: "to_str", value: other.clone() }),
        }
    }
```

and this free function below the `impl`:

```rust
/// Ruby's `String#to_i`: leading whitespace, a sign, then digits with
/// single underscores between them; whatever follows is ignored.
fn string_to_i(s: &str) -> Result<i64> {
    let s = s.trim_start_matches([' ', '\t', '\n', '\u{b}', '\u{c}', '\r']);
    let (sign, rest) = match s.as_bytes().first() {
        Some(b'-') => ("-", &s[1..]),
        Some(b'+') => ("", &s[1..]),
        _ => ("", s),
    };
    let mut digits = String::new();
    let mut underscore = false;
    for c in rest.chars() {
        match c {
            '0'..='9' => {
                digits.push(c);
                underscore = false;
            }
            '_' if !digits.is_empty() && !underscore => underscore = true,
            _ => break,
        }
    }
    if digits.is_empty() {
        return Ok(0);
    }
    let text = format!("{sign}{digits}");
    text.parse().map_err(|_| Error::Overflow { value: text })
}
```

In `src/http/params.rs`, after `value`:

```rust
    /// `params.fetch(:page, 1)`: the value when the key is there (a null
    /// too, as Rails' fetch), `default` when it isn't.
    pub fn fetch(&self, key: &str, default: impl Into<Value>) -> Value {
        self.get(key).map_or_else(|| default.into(), scalar)
    }
```

In `Cargo.toml`, after `[dependencies]`'s entries and before `[workspace]`:

```toml
# Ruby promotes an overflowing Integer to a Bignum. Generated code panics
# (the server's 500) instead of wrapping, in release builds too.
[profile.release]
overflow-checks = true
```

- [ ] **Step 4: Run the tests to watch them pass**

Run: `cargo test --test value_test --test params_test 2>&1 | grep -E 'test result|panicked|^warning'`
Expected: both `ok`, no warnings.

- [ ] **Step 5: Run the workspace**

Run: `cargo test --workspace 2>&1 | grep -E '^test result|^warning'`
Expected: all `ok` (150 in total), no warnings. If a `match` on `Error` elsewhere lists every variant and now fails to compile, add the two new ones to its 500 arm.

- [ ] **Step 6: Commit**

```bash
cd ~/projects/RustOnRails && git add src/value.rs src/error.rs src/http/params.rs Cargo.toml tests/value_test.rs tests/params_test.rs && git commit -m "Value#to_i and #to_str as Ruby's, params.fetch, overflow checks in release"
```

---

### Task 3: Rutile — class-body constants

**Files:**
- Create: `lib/rutile/build/constants.rb`
- Modify: `lib/rutile/build/translator.rb` (drop `constant`, include `Constants`)
- Modify: `lib/rutile/build/types.rb` (`Uses#constant` and the `const` group in `lines`)
- Modify: `lib/rutile/build/source.rb` (`exist?`)
- Modify: `lib/rutile/build.rb` (require)
- Test: `test/build/constants_test.rb` (new)

**Interfaces:**
- Produces:
  - `Constants#constant(node)`, which replaces `Translator#constant`
  - `Uses#constant(name, item) -> bool` (false when `name` is taken by a different item)
  - `Source#exist?(path)`

- [ ] **Step 1: Write the failing tests**

Create `test/build/constants_test.rb`:

```ruby
require_relative "../build_helper"

class ConstantsTest < Minitest::Test
  include BuildHelper

  def posts(app) = Rutile::Build::ControllerFile.new(app, "PostsController").to_rust

  def with_message(ruby) = ruby.sub("class PostsController < ApplicationController\n", "\\0  MISSING = \"no such post\"\n")

  def test_a_controller_constant_is_a_rust_const
    app = scratch_app({ "app/controllers/posts_controller.rb" => lambda do |ruby|
      with_message(ruby).sub("render json: @post\n", "render json: { error: MISSING }\n")
    end })
    rust = posts(app)
    assert_rust_includes rust, %(// app/controllers/posts_controller.rb:2\nconst MISSING: &str = "no such post";)
    assert_rust_includes rust, %(json!({ "error": MISSING }))
  end

  # Ruby looks in the class first, then the one it inherits from.
  def test_a_subclass_constant_hides_application_controllers
    app = scratch_app({
      "app/controllers/application_controller.rb" => ->(ruby) { ruby.sub(/^end\n\z/, "  MISSING = \"gone\"\n  LIMIT = 5\nend\n") },
      "app/controllers/posts_controller.rb" => lambda do |ruby|
        with_message(ruby).sub("render json: @post\n", "render json: { error: MISSING, limit: LIMIT }\n")
      end
    })
    rust = posts(app)
    assert_rust_includes rust, %(const MISSING: &str = "no such post";)
    assert_rust_includes rust, "// app/controllers/application_controller.rb:10\nconst LIMIT: i64 = 5;"
    refute_includes rust, '"gone"'
  end

  # ApplicationController's helper reads its own MISSING, the action
  # PostsController's: two consts with one name in posts.rs.
  def test_a_name_meaning_two_things_in_one_file_is_refused
    app = scratch_app({
      "app/controllers/application_controller.rb" => lambda do |ruby|
        ruby.sub(/^end\n\z/, "  MISSING = \"gone\"\n\n  def missing = MISSING\nend\n")
      end,
      "app/controllers/posts_controller.rb" => lambda do |ruby|
        with_message(ruby).sub("render json: @post\n", "render json: { a: MISSING, b: missing }\n")
      end
    })
    error = assert_raises(Rutile::Build::Unsupported) { posts(app) }
    assert_includes error.message, "MISSING, which means two things in this file"
  end

  def test_a_model_constant_in_a_callback
    app = scratch_app({ "app/models/post.rb" => lambda do |ruby|
      ruby.sub("self.published_at ||= Time.current", "self.comments_count = START").sub(/^end\n\z/, "\n  START = 0\nend\n")
    end })
    rust = Rutile::Build::ModelFile.new(app, "Post").to_rust
    assert_rust_includes rust, "const START: i64 = 0;"
    assert_rust_includes rust, "ctx[post].comments_count = Some(START);"
  end

  def test_a_constant_that_isnt_a_literal_is_refused
    app = scratch_app({ "app/controllers/posts_controller.rb" => lambda do |ruby|
      ruby.sub("class PostsController < ApplicationController\n", "\\0  LIMIT = 5 * 4\n")
          .sub("render json: @post\n", "render json: { limit: LIMIT }\n")
    end })
    error = assert_raises(Rutile::Build::Unsupported) { posts(app) }
    assert_includes error.message, "LIMIT, a constant that isn't an integer, string or boolean"
  end
end
```

- [ ] **Step 2: Run the tests to watch them fail**

Run: `bundle exec ruby -Itest test/build/constants_test.rb 2>&1 | tail -15`
Expected: failures and errors of the form "the constant MISSING isn't supported yet" (the translator knows only models and `Time`).

- [ ] **Step 3: Implement**

Create `lib/rutile/build/constants.rb`:

```ruby
module Rutile
  module Build
    # Constants a class body assigns a literal: `PER_PAGE = 20`. Ruby looks a
    # constant up in the class whose method reads it, then in the class that
    # one inherits from: a controller method sees its class's constants and
    # then ApplicationController's, a model method its model's and then
    # ApplicationRecord's. Each one read becomes a Rust `const` in the file.
    module Constants
      PARENTS = { controller: "app/controllers/application_controller.rb", model: "app/models/application_record.rb",
                  scope: "app/models/application_record.rb" }.freeze

      private

      def constant(node)
        name = node.name.to_s
        return Code["Time", T::TIME_CLASS] if name == "Time"

        home = [@path, PARENTS[@env]].compact.uniq.find { assignments(_1).key?(name) }
        return class_constant(name, home, node) if home

        unsupported!(node, "the constant #{name}") unless @app.model?(name)
        use_model(name)
        Code[name, T.klass(name)]
      end

      def class_constant(name, path, node)
        assignment = assignments(path)[name]
        type, rust_type, value = literal_constant(assignment.value) ||
                                 unsupported!(node, "#{name}, a constant that isn't an integer, string or boolean")
        rust = Names.constant(Names.snake(name))
        item = "// #{path}:#{assignment.location.start_line}\nconst #{rust}: #{rust_type} = #{value};"
        @uses.constant(rust, item) || unsupported!(node, "#{name}, which means two things in this file")
        type == T::STR ? Code[rust, type, literal: true] : Code[rust, type]
      end

      # name => its last assignment in the file's class body. A file with
      # more than one class has none: which class a constant is in is
      # beyond this.
      def assignments(path)
        @assignments ||= {}
        @assignments[path] ||= begin
          classes = @app.source.exist?(path) ? Declarations.classes(@app.source.tree(path)) : []
          body = classes.size == 1 ? classes.first.body : nil
          statements = body.is_a?(Prism::StatementsNode) ? body.body : []
          statements.grep(Prism::ConstantWriteNode).to_h { [_1.name.to_s, _1] }
        end
      end

      # [type, Rust type, Rust value] of a literal, frozen or not.
      def literal_constant(value)
        value = value.receiver if value.is_a?(Prism::CallNode) && value.name == :freeze && value.receiver && !value.arguments
        case value
        when Prism::IntegerNode then [T::INT, "i64", value.value.to_s] if value.value.bit_length < 64
        when Prism::StringNode, Prism::SymbolNode then [T::STR, "&str", Names.str(value.unescaped)]
        when Prism::TrueNode, Prism::FalseNode then [T::BOOL, "bool", value.is_a?(Prism::TrueNode).to_s]
        end
      end
    end
  end
end
```

(`to_h` keeps the last assignment of a name, which is the value Ruby's class body leaves.)

In `lib/rutile/build/translator.rb`, add `include Constants` after `include Expressions`, and delete the `constant(node)` method (it moved). The `when Prism::ConstantReadNode then constant(node)` line stays.

In `lib/rutile/build/types.rb`, in `Uses#initialize` add `@constants = {}`. After `def line(text)` add:

```ruby
      # A `const` item; false when the name already holds a different one.
      def constant(name, item) = (@constants[name] ||= item) == item
```

In `lines`, after `groups << @lines unless @lines.empty?`, add `groups << @constants.values unless @constants.empty?`.

In `lib/rutile/build/source.rb`, after `tree`:

```ruby
      def exist?(path) = File.file?(File.join(@root, path))
```

In `lib/rutile/build.rb`, add `require_relative "build/constants"` before `require_relative "build/translator"`.

- [ ] **Step 4: Run the tests to watch them pass**

Run: `bundle exec ruby -Itest test/build/constants_test.rb 2>&1 | tail -3`
Expected: `5 runs, ... 0 failures, 0 errors`.

- [ ] **Step 5: Run the suite and the blog regression**

Run: `bundle exec rake test 2>&1 | grep 'runs,'; bundle exec rake example:check | tail -1; bundle exec rake example:build >/dev/null && git -C ../RustOnRails status --short examples; wc -l lib/rutile/build/translator.rb`
Expected: 0 failures; `no problems`; no status lines; translator.rb under 300 lines.

- [ ] **Step 6: Commit**

```bash
git add lib/rutile/build/constants.rb lib/rutile/build/translator.rb lib/rutile/build/types.rb lib/rutile/build/source.rb lib/rutile/build.rb test/build/constants_test.rb && git commit -m "rutile build: class-body constants as Rust consts, looked up as Ruby does"
```

---

### Task 4: Rutile — arithmetic, [a, b].max, params.fetch, to_i

**Files:**
- Modify: `lib/rutile/build/expressions.rb` (`arithmetic`, `operand`, `extremum`)
- Modify: `lib/rutile/build/translator.rb` (dispatch in `call`)
- Modify: `lib/rutile/build/web_calls.rb` (`fetch`, `to_i`)
- Modify: `lib/rutile/build/crate.rb` (`[profile.release]` in the template)
- Test: `test/build/numbers_test.rb` (new)

**Interfaces:**
- Consumes: Task 2's `Params::fetch(key, default) -> Value` and `Value::to_i() -> Result<i64>`
- Produces:
  - `Expressions::ARITHMETIC = %w[+ - *]`
  - Codes for arithmetic carry `extra[:arith]` (the operator), which `operand` reads for grouping

- [ ] **Step 1: Write the failing tests**

Create `test/build/numbers_test.rb`:

```ruby
require_relative "../build_helper"

class NumbersTest < Minitest::Test
  include BuildHelper

  def callback(ruby, model: "Post")
    translator = Rutile::Build::Translator.new(app, "snippet.rb", Rutile::Build::Uses.new, env: :model, model:,
                                                                                           self_var: Rutile::Build::Names.snake(model))
    translator.body(Prism.parse(ruby).value.statements, :unit).first.join("\n")
  end

  def refused(message, &)
    error = assert_raises(Rutile::Build::Unsupported, &)
    assert_includes error.message, message
  end

  def test_arithmetic_keeps_rubys_grouping
    assert_rust_includes callback("self.comments_count = 1 - (2 - 3)"), "ctx[post].comments_count = Some(1 - (2 - 3));"
    assert_rust_includes callback("self.comments_count = 2 * (3 + 4)"), "Some(2 * (3 + 4));"
    assert_rust_includes callback("self.comments_count = 2 * 3 + 4 - 1"), "Some(2 * 3 + 4 - 1);"
  end

  # Ruby raises NoMethodError on nil - 1.
  def test_a_nil_operand_is_error_nil
    assert_rust_includes callback("self.comments_count = (comments_count - 1) * 2"), <<~RUST
      let value = (ctx[post].comments_count.ok_or(Error::Nil { what: "-" })? - 1) * 2;
      ctx[post].comments_count = Some(value);
    RUST
  end

  def test_arithmetic_outside_numbers_is_refused
    refused("+ between str and str") { callback('self.title = "a" + "b"') }
    refused("+ between int and nil") { callback("self.comments_count = 1 + nil") }
    refused("/ on int") { callback("self.comments_count = 7 / 2") }
    refused("max over int or nil and int") { callback("self.comments_count = [comments_count, 1].max") }
  end

  # ApplicationController#page in the tracker: [params.fetch(:page, 1).to_i, 1].max
  def test_page_from_params_like_rails
    app = scratch_app({ "app/controllers/posts_controller.rb" => lambda do |ruby|
      ruby.sub("@post = Post.find(params[:id])", "@post = Post.find([params.fetch(:id, 1).to_i, 1].max)")
    end })
    rust = Rutile::Build::ControllerFile.new(app, "PostsController").to_rust
    assert_rust_includes rust, 'Post::find(&mut req.ctx, i64::max(req.params.fetch("id", 1).to_i()?, 1))?'
  end

  def test_fetch_needs_a_literal_default
    %w[params.fetch(:id) params.fetch(:id,\ Time.current)].zip(["fetch without a default", "a fetch default that isn't a literal"])
                                                         .each do |call, message|
      app = scratch_app({ "app/controllers/posts_controller.rb" => ->(ruby) { ruby.sub("params[:id]", "#{call}.to_i") } })
      refused(message) { Rutile::Build::ControllerFile.new(app, "PostsController").to_rust }
    end
  end

  def test_generated_crates_check_integer_overflow
    toml = Rutile::Build::Crate.new(app, Dir.mktmpdir, name: "x", runtime: "/tmp/rustonrails").send(:cargo_toml)
    assert_includes toml, "[profile.release]\noverflow-checks = true\n"
  end
end
```

- [ ] **Step 2: Run the tests to watch them fail**

Run: `bundle exec ruby -Itest test/build/numbers_test.rb 2>&1 | tail -20`
Expected: every test fails. The errors say "- on int", "array", "fetch on params" or "to_i on value", and the template test fails because the TOML has no profile.

- [ ] **Step 3: Implement**

In `lib/rutile/build/expressions.rb`, after `ORDERED`:

```ruby
      ARITHMETIC = %w[+ - *].freeze
      # How tightly Rust binds each operator.
      BINDS = { "+" => 1, "-" => 1, "*" => 2 }.freeze
```

and after `nil_compare`:

```ruby
      # `a + b`, `a - b`, `a * b` on two Integers or two Floats. Ruby
      # promotes an overflowing Integer to a Bignum; generated crates build
      # with overflow-checks, so Rust panics (a 500) instead of wrapping.
      # A nil operand raises, as it does in Ruby.
      def arithmetic(node, name, arg)
        left, right = in_order([node.receiver, arg]) { value(_1) }.map { unwrap(_1, name) }
        unless left.type == right.type && %i[int float].include?(left.type.kind)
          unsupported!(node, "#{name} between #{describe(left.type)} and #{describe(right.type)}")
        end
        left, right = settle([left, right], :none)
        rust = "#{operand(left, name, false)} #{name} #{operand(right, name, true)}"
        Code[rust, left.type, touch(left, right), arith: name]
      end

      # Parentheses where Rust would regroup: a looser operator inside a
      # tighter one, an equal one on the right (`a - (b - c)`), an `if`.
      def operand(code, name, right)
        inner = code.extra[:arith]
        loose = inner && (BINDS[inner] < BINDS[name] || (right && BINDS[inner] == BINDS[name]))
        loose || code.rust.start_with?("if ") ? "(#{code.rust})" : code.rust
      end

      # `[a, b].max`: Integers only; Ruby raises comparing nil.
      def extremum(node, name)
        elements = node.receiver.elements
        unsupported!(node, "#{name} of an empty array") if elements.empty?
        codes = in_order(elements) { value(_1) }
        unless codes.all? { _1.type == T::INT }
          unsupported!(node, "#{name} over #{codes.map { describe(_1.type) }.uniq.join(" and ")}")
        end
        codes = settle(codes, :none)
        Code[codes.map(&:rust).reduce { |a, b| "i64::#{name}(#{a}, #{b})" }, T::INT, touch(*codes)]
      end
```

In `lib/rutile/build/translator.rb`, in `call`:
- After `return self_call(node, name, args) if node.receiver.nil?`, add `return extremum(node, name) if node.receiver.is_a?(Prism::ArrayNode) && %w[max min].include?(name) && args.empty?`.
- Change the `operator` line to `operator = name == "!" || (Expressions::COMPARE + Expressions::ARITHMETIC).include?(name)`.
- After the `return compare(...)` line, add `return arithmetic(node, name, args.first) if Expressions::ARITHMETIC.include?(name) && args.size == 1`.

In `lib/rutile/build/web_calls.rb`, in `on_params`, add a branch before `when "require"`:

```ruby
        when "fetch"
          unsupported!(node, "fetch without a default") unless args.size == 2
          key, default = args
          Code["#{receiver.rust}.fetch(#{Names.str(symbol!(key, node))}, #{fetch_default(default, node)})", T::VALUE,
               hint: key.unescaped]
```

After `on_params`, add:

```ruby
      # What `fetch` gives back when the key is absent: a literal.
      def fetch_default(node, at)
        case node
        when Prism::IntegerNode, Prism::TrueNode, Prism::FalseNode, Prism::StringNode, Prism::SymbolNode then expr(node).rust
        when Prism::NilNode
          @uses.rt("Value")
          "Value::Nil"
        else unsupported!(at, "a fetch default that isn't a literal")
        end
      end
```

In `on_value`, add a branch after `when "to_s"`:

```ruby
        when "to_i" then Code["#{receiver.rust}.to_i()?", T::INT, receiver.ctx, hint: receiver.hint]
```

In `lib/rutile/build/crate.rb`, end the `cargo_toml` heredoc with:

```
          [dependencies]
          rustonrails = { path = "#{runtime}" }

          # Ruby promotes an overflowing Integer to a Bignum. This crate panics
          # (the server's 500) instead of wrapping, in release builds too.
          [profile.release]
          overflow-checks = true
```

(Keep the lines that are already there. Only the blank line, the comment and the two profile lines are new. A Cargo.toml that already exists isn't rewritten, so the blog crate, a workspace member, is unaffected; the workspace root has the profile from Task 2.)

- [ ] **Step 4: Run the tests to watch them pass**

Run: `bundle exec ruby -Itest test/build/numbers_test.rb 2>&1 | tail -3`
Expected: `7 runs, ... 0 failures, 0 errors`.

- [ ] **Step 5: Run the suite and the blog regression**

Run: `bundle exec rake test 2>&1 | grep 'runs,'; bundle exec rake example:check | tail -1; bundle exec rake example:build >/dev/null && git -C ../RustOnRails status --short examples; wc -l lib/rutile/build/{translator,expressions,web_calls}.rb`
Expected: 0 failures; `no problems`; no status lines; every file under 300 lines.

- [ ] **Step 6: Commit**

```bash
git add lib/rutile/build/expressions.rb lib/rutile/build/translator.rb lib/rutile/build/web_calls.rb lib/rutile/build/crate.rb test/build/numbers_test.rb && git commit -m "rutile build: + - * with overflow checks, [a, b].max, params.fetch and to_i"
```

---

### Task 5: Rutile — limit/offset expressions, joins, where on joined tables

**Files:**
- Create: `lib/rutile/build/queries.rb`. Move `where`, `order` and `include_one` here from `model_calls.rb`; `where` becomes `where_pairs`/`condition`.
- Modify: `lib/rutile/build/model_calls.rb` (`on_relation`, `association`, `scope_call`)
- Modify: `lib/rutile/build/borrowing.rb` (`after`)
- Modify: `lib/rutile/build/translator.rb` (`include Queries`)
- Modify: `lib/rutile/build.rb` (require)
- Test: `test/build/queries_test.rb` (new)

**Interfaces:**
- Consumes: Task 1's `Relation::offset`, `Relation::joins(&Assoc::CONST)` and `Relation::where_on::<J>(column, value)`; Task 3's constants and Task 4's arithmetic (the tracker's index uses both).
- Produces:
  - `Borrowing#after(receiver) { ... } -> [receiver, result]`
  - `Queries#relation(receiver, rust, *codes) -> Code`, which carries `extra[:joined]`, a hash of table name to model
  - `Queries#bindable!(code, node, what)`
  - `Queries#where_value(code) -> String`

- [ ] **Step 1: Write the failing tests**

Create `test/build/queries_test.rb`:

```ruby
require_relative "../build_helper"
require_relative "../tracker_helper"

class QueriesTest < Minitest::Test
  include BuildHelper
  include TrackerHelper

  def controller(name, app = tracker) = [Rutile::Build::ControllerFile.new(app, name).to_rust, app.diagnostics.problems]

  def translate(ruby, model:, app: tracker)
    translator = Rutile::Build::Translator.new(app, "snippet.rb", Rutile::Build::Uses.new, env: :model, model:,
                                                                                           self_var: Rutile::Build::Names.snake(model))
    translator.body(Prism.parse(ruby).value.statements, :unit).first.join("\n")
  end

  def refused(message, &)
    error = assert_raises(Rutile::Build::Unsupported, &)
    assert_includes error.message, message
  end

  # projects#index: current_user.projects.active.order(:name).limit(PER_PAGE).offset((page - 1) * PER_PAGE)
  def test_pagination_with_a_constant_and_arithmetic
    rust, problems = controller("ProjectsController")
    refute problems.any? { _1.start_with?("app/controllers/projects_controller.rb:7:") }, problems.join("\n")
    assert_rust_includes rust, "// app/controllers/projects_controller.rb:2\nconst PER_PAGE: i64 = 20;"
    assert_rust_includes rust, '.active().order_asc("name").limit(PER_PAGE);'
    assert_rust_includes rust, ".offset((self.page(req)? - 1) * PER_PAGE);"
    assert_rust_includes rust, <<~RUST
      fn page(&mut self, req: &mut Request) -> Result<i64> {
          Ok(i64::max(req.params.fetch("page", 1).to_i()?, 1))
      }
    RUST
  end

  # set_task: Task.joins(project: :memberships).where(memberships: { user_id: current_user.id }).find(params[:id])
  def test_joins_and_a_where_on_the_joined_table
    rust, problems = controller("TasksController")
    refute problems.any? { _1.start_with?("app/controllers/tasks_controller.rb:43:") }, problems.join("\n")
    assert_rust_includes rust, "Task::all().joins(&Task::PROJECT).joins(&Project::MEMBERSHIPS)" \
                               '.where_on::<Membership>("user_id", req.ctx[self.current_user.ok_or(Error::Nil { what: "id" })?].id)' \
                               '.find(&mut req.ctx, req.params.value("id"))?'
  end

  # has_many :through joins its join table, so a where can name it.
  def test_where_on_the_through_join_table
    assert_rust_includes translate('found = projects.where(memberships: { role: "admin" })', model: "User"),
                         'let found = User::PROJECTS.of(ctx, user).where_on::<Membership>("role", "admin");'
  end

  def test_joins_that_would_break_are_refused
    refused("joining projects twice") { translate("found = Task.joins(:project, :project)", model: "Task") }
    refused("joining tasks twice") { translate("found = Task.joins(project: :tasks)", model: "Task") }
    refused("joins(:members), a has_many through memberships") { translate("found = Project.joins(:members)", model: "Project") }
    refused("joins(:nothing), which Task doesn't have") { translate("found = Task.joins(:nothing)", model: "Task") }
    refused("a list that isn't symbols") { translate("found = Task.joins(project: { memberships: :user })", model: "Task") }
    refused("where on users, which the relation doesn't join") do
      translate("found = Task.joins(:project).where(users: { id: 1 })", model: "Task")
    end
    refused("limit with int or nil") { translate("found = Task.limit(estimate)", model: "Task") }
  end
end
```

- [ ] **Step 2: Run the tests to watch them fail**

Run: `bundle exec ruby -Itest test/build/queries_test.rb 2>&1 | tail -25`
Expected: all four tests fail. The failures show "a non-literal limit", "joins on Task" and "where on memberships, which User doesn't have".

- [ ] **Step 3: Implement**

In `lib/rutile/build/borrowing.rb`, after `in_order`:

```ruby
      # Evaluates what Ruby evaluates after `receiver`, a call's arguments.
      # If that ran statements or writes the Ctx, the receiver becomes a
      # local first, so it reads the Ctx before they run. Returns the
      # receiver and the block's result, whose Codes are checked for writes.
      def after(receiver)
        mark = @lines.size
        result = yield
        writes = [result].flatten.any? { _1.is_a?(Code) && _1.writes? }
        return [receiver, result] unless receiver.reads? && (writes || @lines.size > mark)

        name = fresh(receiver.hint || "value")
        @lines.insert(mark, "let #{name} = #{receiver.rust};")
        [Code[name, receiver.type, hint: receiver.hint, **receiver.extra.except(:literal, :local, :safe, :nav)], result]
      end
```

Create `lib/rutile/build/queries.rb`:

```ruby
module Rutile
  module Build
    # A relation's query methods: where (on the model's columns or a joined
    # table's), order, limit, offset, joins and includes. Each keeps the SQL
    # Rails would run or is refused. A relation's Code carries the tables it
    # joins in `extra[:joined]` (table => model).
    module Queries
      SCALARS = %i[str int float bool time value].freeze

      private

      # The next relation in a chain.
      def relation(receiver, rust, *codes)
        Code[rust, T.relation(receiver.type.model), touch(receiver, *codes), hint: receiver.hint, **receiver.extra.slice(:joined)]
      end

      # `where(status: :done, memberships: { user_id: id })`: a hash value
      # names a table the relation joins, by association or by table name.
      def where_pairs(receiver, model, args, node)
        joined = receiver.extra[:joined] || {}
        receiver, conditions = after(receiver) do
          pairs(args, node).flat_map do |key, operand|
            next [condition(model, key, operand, node)] unless hash?(operand)

            target = joined_model(model, key, joined, node)
            pairs([operand], node).map { |column, value| joined_condition(target, column, value, node) }
          end
        end
        relation(receiver, "#{receiver.rust}#{conditions.map(&:first).join}", *conditions.map(&:last))
      end

      # [Rust, Code] for one condition on the model's own column.
      def condition(model, column, operand, node)
        if operand.is_a?(Prism::RangeNode)
          unsupported!(node, "a where range other than `x..`") unless operand.left && operand.right.nil? && !operand.exclude_end?
          bound = value(operand.left)
          unsupported!(node, "a where range from a value that may be nil") if bound.type.nilable?
          return [".where_gte(#{Names.str(column)}, #{owned(bound)})", bound]
        end
        unsupported!(node, "where on #{column}, which #{model} doesn't have") unless @app.column_type(model, column)
        code = value(operand)
        bindable!(code, node, "where")
        [".where_eq(#{Names.str(column)}, #{where_value(code)})", code]
      end

      def joined_condition(target, column, operand, node)
        unsupported!(node, "where on #{column}, which #{target} doesn't have") unless @app.column_type(target, column)
        unsupported!(node, "a where range on a joined table") if operand.is_a?(Prism::RangeNode)
        code = value(operand)
        bindable!(code, node, "where")
        use_model(target)
        [".where_on::<#{target}>(#{Names.str(column)}, #{where_value(code)})", code]
      end

      def joined_model(model, key, joined, node)
        assoc = @app.association(model, key)
        table = assoc ? @app.model(assoc["class_name"])["table_name"] : key
        joined[table] || unsupported!(node, "where on #{key}, which the relation doesn't join")
      end

      # nil is SQL's NULL; so is a value that turns out nil.
      def where_value(code)
        return owned(code) unless code.type == T::NIL

        @uses.rt("Value")
        "Value::Nil"
      end

      # What a query can bind: a scalar, or one that may be nil.
      def bindable!(code, node, what)
        kind = code.type.nilable? ? code.type.inner.kind : code.type.kind
        unsupported!(node, "#{what} with #{describe(code.type)}") unless SCALARS.include?(kind) || code.type == T::NIL
      end

      def order(args, node)
        args.flat_map do |arg|
          next [".order_asc(#{Names.str(symbol!(arg, node))})"] if arg.is_a?(Prism::SymbolNode)

          pairs([arg], node).map do |column, direction|
            dir = symbol!(direction, node)
            unsupported!(node, "order direction :#{dir}") unless %w[asc desc].include?(dir)
            ".order_#{dir}(#{Names.str(column)})"
          end
        end.join
      end

      # `limit(n)`, `offset(n)`: an Integer, read after the relation.
      def paginate(receiver, name, args, node)
        receiver, count = after(receiver) { value(only(args, node)) }
        unsupported!(node, "#{name} with #{describe(count.type)}") unless count.type == T::INT
        relation(receiver, "#{receiver.rust}.#{name}(#{count.rust})", count)
      end

      # `joins(:project)`, `joins(project: :memberships)`: inner joins along
      # belongs_to and has_many, each table once, since Rails would alias a
      # second one.
      def joins(receiver, model, args, node)
        joined = (receiver.extra[:joined] || {}).dup
        steps = args.flat_map do |arg|
          next [[model, symbol!(arg, node)]] unless hash?(arg)

          pairs([arg], node).flat_map do |name, nested|
            target = join_target(model, name, node)
            [[model, name], *symbols(nested, node).map { [target, _1] }]
          end
        end
        rust = steps.map do |owner, name|
          target = join_target(owner, name, node)
          table = @app.model(target)["table_name"]
          unsupported!(node, "joining #{table} twice") if table == @app.model(model)["table_name"] || joined.key?(table)
          joined[table] = target
          use_model(owner)
          ".joins(&#{owner}::#{Names.constant(name)})"
        end
        Code["#{receiver.rust}#{rust.join}", T.relation(model), receiver.ctx, hint: receiver.hint, joined:]
      end

      def join_target(owner, name, node)
        assoc = @app.association(owner, name) or unsupported!(node, "joins(:#{name}), which #{owner} doesn't have")
        through = assoc["options"]["through"]
        extra = assoc["options"].keys - ModelFile::ASSOCIATION_OPTIONS
        unless %w[belongs_to has_many].include?(assoc["macro"]) && !through && extra.empty?
          unsupported!(node, "joins(:#{name}), a #{assoc["macro"]}#{" through #{through}" if through}" \
                             "#{" with #{extra.join(", ")}" unless extra.empty?}")
        end
        assoc["class_name"]
      end

      # Preloading a through association isn't built yet.
      def include_one(model, name, node)
        through = @app.association(model, name)&.dig("options", "through")
        unsupported!(node, "including #{name} through #{through}") if through
        ".includes(&#{model}::#{Names.constant(name)})"
      end
    end
  end
end
```

In `lib/rutile/build/model_calls.rb`:
- Delete `include_one`, `where` and `order` (moved).
- In `on_relation`, replace the `chain` lambda and the `where`/`limit`/`includes` branches:

```ruby
        chain = ->(rust) { relation(receiver, "#{receiver.rust}#{rust}") }
        case name
        when "where"
          return Code[receiver.rust, T.where_chain(model), receiver.ctx, hint: receiver.hint] if args.empty?

          where_pairs(receiver, model, args, node)
        when "order" then chain.(order(args, node))
        when "limit", "offset" then paginate(receiver, name, args, node)
        when "joins" then joins(receiver, model, args, node)
        when "includes" then chain.(args.map { include_one(model, symbol!(_1, node), node) }.join)
```

(The rest of the `case` stays.)
- In `association`, the through branch becomes:

```ruby
        if assoc["options"]["through"]
          link, = ModelFile.through_parts(@app, model, assoc)
          unsupported!(node, "has_many :#{assoc["name"]} through #{assoc["options"]["through"]} in this shape") unless link
          joined = { @app.model(link["class_name"])["table_name"] => link["class_name"] }
          return Code["#{const}.of(#{ctx_ref}, #{receiver.rust})", T.relation(target), :read, hint: assoc["name"],
                      through: assoc["name"], joined:]
        end
```

- In `scope_call`, replace its `Code[...]` line with `relation(receiver, "#{receiver.rust}.#{name}(#{values.join(", ")})")`, so a scope keeps the joins before it.

In `lib/rutile/build/translator.rb`, add `include Queries` after `include Constants`. In `lib/rutile/build.rb`, add `require_relative "build/queries"` before `require_relative "build/translator"`.

- [ ] **Step 4: Run the tests to watch them pass**

Run: `bundle exec ruby -Itest test/build/queries_test.rb 2>&1 | tail -3`
Expected: `4 runs, ... 0 failures, 0 errors`.

- [ ] **Step 5: Run the suite and the blog regression**

Run: `bundle exec rake test 2>&1 | grep 'runs,'; bundle exec rake example:check | tail -1; bundle exec rake example:build >/dev/null && git -C ../RustOnRails status --short examples; bundle exec rake example:verify 2>&1 | grep 'runs,'; wc -l lib/rutile/build/{model_calls,queries,borrowing,translator}.rb`
Expected: 0 failures; `no problems`; no status lines (the blog's `limit(20)` still compiles to `.limit(20)`); verify 17/17; every file under 300 lines.

- [ ] **Step 6: Commit**

```bash
git add lib/rutile/build/queries.rb lib/rutile/build/model_calls.rb lib/rutile/build/borrowing.rb lib/rutile/build/translator.rb lib/rutile/build.rb test/build/queries_test.rb && git commit -m "rutile build: limit/offset with any Integer, joins, where on joined tables"
```

---

### Task 6: Rutile — SQL fragments, interpolation, sanitize_sql_like, scope arguments

**Files:**
- Create: `lib/rutile/build/scope_parameters.rb`. Move `parameters`, `parameter_types` and `each_where_pair` here from `scopes_file.rb`.
- Modify: `lib/rutile/build/scopes_file.rb` (use `ScopeParameters.of`)
- Modify: `lib/rutile/build/queries.rb` (`where_sql`, `sanitize_like`)
- Modify: `lib/rutile/build/model_calls.rb` (the `where` and `sanitize_sql_like` branches, `scope_call` and `scope_arguments`)
- Modify: `lib/rutile/build/expressions.rb` (`interpolation`)
- Modify: `lib/rutile/build/translator.rb` (`expr` handles `InterpolatedStringNode`)
- Modify: `lib/rutile/build.rb` (require)
- Test: `test/build/fragments_test.rb` (new)

**Interfaces:**
- Consumes: Task 1's `Relation::where_sql(sql, Vec<Value>)` and `sanitize_sql_like(&str)`; Task 2's `Value::to_str() -> Result<String>`; Task 5's `relation`, `after`, `bindable!` and `where_value`.
- Produces: `ScopeParameters.of(app, model, lambda_node, path) -> [names, { name => Type }, strings]`

- [ ] **Step 1: Write the failing tests**

Create `test/build/fragments_test.rb`:

```ruby
require_relative "../build_helper"
require_relative "../tracker_helper"

class FragmentsTest < Minitest::Test
  include BuildHelper
  include TrackerHelper

  def translate(ruby, model: "Task")
    translator = Rutile::Build::Translator.new(tracker, "snippet.rb", Rutile::Build::Uses.new, env: :model, model:,
                                                                                               self_var: Rutile::Build::Names.snake(model))
    translator.body(Prism.parse(ruby).value.statements, :unit).first.join("\n")
  end

  def refused(message, &)
    error = assert_raises(Rutile::Build::Unsupported, &)
    assert_includes error.message, message
  end

  # scope :search, ->(query) { where("title ILIKE ?", "%#{sanitize_sql_like(query)}%") }
  def test_a_search_scope_binds_an_escaped_pattern
    rust = Rutile::Build::Scopes.for_model(tracker, Rutile::Build::Uses.new, "Task")
    assert_rust_includes rust, <<~RUST
      // app/models/task.rb:13
      fn search(self, query: String) -> Self {
          self.where_sql("title ILIKE ?", vec![format!("%{}%", sanitize_sql_like(&query)).into()])
      }
    RUST
  end

  # tasks#index: tasks = tasks.search(params[:q]) if params[:q].present?
  # (with its last line, a map block, swapped for a plain render)
  def test_a_param_passed_where_a_string_is_wanted_must_be_one
    app = scratch_app({ "app/controllers/tasks_controller.rb" => ->(ruby) { ruby.sub(/render json: tasks\.map.*$/, "render json: tasks") } },
                      from: TrackerHelper::APP, manifest: TrackerHelper.manifest, diagnostics: Rutile::Build::Diagnostics.new)
    rust = Rutile::Build::ControllerFile.new(app, "TasksController").to_rust
    refute app.diagnostics.problems.any? { _1.start_with?("app/controllers/tasks_controller.rb:") && _1.include?(":8:") }
    assert_rust_includes rust, 'tasks = tasks.search(req.params.value("q").to_str()?);'
  end

  def test_interpolation_formats_and_escapes_braces
    assert_rust_includes translate('x = "a"; found = Task.where("title = ?", "{#{x}}-#{1}")'),
                         'Task::all().where_sql("title = ?", vec![format!("{{{}}}-{}", x, 1).into()])'
  end

  def test_fragments_that_would_bind_wrong_are_refused
    refused("a SQL fragment with 2 ? and 1 value") { translate('found = Task.where("a = ? AND b = ?", 1)') }
    refused("a SQL fragment with $") { translate('found = Task.where("a = $1")') }
    refused("sanitize_sql_like with int") { translate("found = Task.sanitize_sql_like(1)") }
    refused("passing int to scope :search's query (str)") { translate("found = Task.search(1)") }
    refused("interpolating int or nil") { translate('found = Task.where("title = ?", "#{estimate}")') }
  end
end
```

- [ ] **Step 2: Run the tests to watch them fail**

Run: `bundle exec ruby -Itest test/build/fragments_test.rb 2>&1 | tail -25`
Expected: all four tests fail. The failures show "a scope parameter (query) not compared with a column", "a non-hash argument" and "interpolated string".

- [ ] **Step 3: Implement**

Create `lib/rutile/build/scope_parameters.rb`:

```ruby
module Rutile
  module Build
    # A lambda scope's parameters and their types, for the scope itself and
    # for code that calls it. A parameter compared with a column in `where`
    # has the column's type. One passed to `sanitize_sql_like` is a String,
    # and a caller's param value must be one (those are `strings`).
    module ScopeParameters
      module_function

      # [names, { name => type }, strings]
      def of(app, model, node, path)
        raise Unsupported.at(path, node, "a scope body that isn't a lambda") unless node.is_a?(Prism::LambdaNode)

        names = names(node, path)
        types = {}
        each_where_pair(node) do |column, value|
          value = value.left if value.is_a?(Prism::RangeNode)
          next unless value.is_a?(Prism::LocalVariableReadNode) && names.include?(value.name.to_s)

          types[value.name.to_s] ||= app.column_type(model, column)
        end
        strings = like_arguments(node) & names
        strings.each { types[_1] ||= T::STR }
        missing = names - types.compact.keys
        raise Unsupported.at(path, node, "a scope parameter (#{missing.join(", ")}) not compared with a column") unless missing.empty?

        [names, types, strings]
      end

      def names(node, path)
        params = node.parameters&.parameters or return []
        plain = params.optionals.empty? && params.posts.empty? && params.keywords.empty? &&
                params.rest.nil? && params.keyword_rest.nil? && params.block.nil? &&
                params.requireds.all?(Prism::RequiredParameterNode)
        raise Unsupported.at(path, node, "scope parameters other than plain ones") unless plain

        params.requireds.map { _1.name.to_s }
      end

      def each_where_pair(node, &block)
        if node.is_a?(Prism::CallNode) && node.name == :where
          (node.arguments&.arguments || []).each do |arg|
            next unless arg.is_a?(Prism::KeywordHashNode) || arg.is_a?(Prism::HashNode)

            arg.elements.each { yield _1.key.unescaped, _1.value if _1.is_a?(Prism::AssocNode) && _1.key.is_a?(Prism::SymbolNode) }
          end
        end
        node.compact_child_nodes.each { each_where_pair(_1, &block) }
      end

      # Locals passed to `sanitize_sql_like`.
      def like_arguments(node, found = [])
        if node.is_a?(Prism::CallNode) && node.name == :sanitize_sql_like
          arg = node.arguments&.arguments&.first
          found << arg.name.to_s if arg.is_a?(Prism::LocalVariableReadNode)
        end
        node.compact_child_nodes.each { like_arguments(_1, found) }
        found
      end
    end
  end
end
```

In `lib/rutile/build/scopes_file.rb`, `lambda_scope` starts:

```ruby
      def lambda_scope(scope)
        path, line = scope["source"].values_at("path", "line")
        node = @app.source.block_at(path, line)
        names, types, = ScopeParameters.of(@app, @model, node, path)
```

Delete the old `raise ... unless node.is_a?(Prism::LambdaNode)` line, the `names = parameters(...)` and `types = parameter_types(...)` lines, and the methods `parameters`, `parameter_types` and `each_where_pair`. The rest of `lambda_scope` stays.

In `lib/rutile/build/queries.rb`, add:

```ruby
      # `where("title ILIKE ?", pattern)`: a SQL fragment with one bind per
      # `?`, as Rails' sanitize_sql_array counts them.
      def where_sql(receiver, args, node)
        sql = args.first.unescaped
        binds = args.drop(1)
        unless sql.count("?") == binds.size
          unsupported!(node, "a SQL fragment with #{sql.count("?")} ? and #{binds.size} value#{"s" unless binds.size == 1}")
        end
        # Its binds become $1, $2, ...; a $ of its own would collide.
        unsupported!(node, "a SQL fragment with $") if sql.include?("$")
        receiver, codes = after(receiver) { in_order(binds) { value(_1) } }
        codes.each { bindable!(_1, node, "a SQL bind") }
        list = codes.map { "#{where_value(_1)}.into()" }
        relation(receiver, "#{receiver.rust}.where_sql(#{Names.str(sql)}, vec![#{list.join(", ")}])", *codes)
      end

      # `sanitize_sql_like(query)`, with Rails' default escape character.
      def sanitize_like(args, node)
        code = value(only(args, node))
        unsupported!(node, "sanitize_sql_like with #{describe(code.type)}") unless code.type == T::STR
        @uses.rt("sanitize_sql_like")
        Code["sanitize_sql_like(#{code.extra[:literal] ? code.rust : "&#{code.rust}"})", T::STR, code.ctx]
      end
```

In `lib/rutile/build/model_calls.rb`, in `on_relation`:
- The `where` branch's last line becomes `args.first.is_a?(Prism::StringNode) ? where_sql(receiver, args, node) : where_pairs(receiver, model, args, node)`.
- Add `when "sanitize_sql_like" then sanitize_like(args, node)` before `else scope_call(...)`.
- Replace `scope_call` with:

```ruby
      def scope_call(receiver, model, name, node, args)
        scope = @app.scope(model, name) or return nil
        path = scope.dig("source", "path")
        trait = path == Scopes::APPLICATION_RECORD ? "ApplicationRecordScopes" : "#{model}Scopes"
        use_model(trait) unless trait == "#{@model}Scopes" && %i[model scope].include?(@env)
        receiver, values = after(receiver) { scope_arguments(model, scope, args, node) }
        relation(receiver, "#{receiver.rust}.#{name}(#{values.map(&:first).join(", ")})", *values.map(&:last))
      end

      # The arguments as the scope's parameters type them. A param value
      # goes where a String is wanted only as a String (`to_str`): the String
      # methods the scope calls would raise on anything else.
      def scope_arguments(model, scope, args, node)
        if scope["origin"] == "framework"
          unsupported!(node, "arguments to scope :#{scope["name"]}") unless args.empty?
          return []
        end
        path, line = scope["source"].values_at("path", "line")
        names, types, strings = begin
          ScopeParameters.of(@app, model, @app.source.block_at(path, line), path)
        rescue Unsupported
          raise Skipped, scope["name"] # the model file reports why
        end
        unsupported!(node, "scope :#{scope["name"]} with #{args.size} arguments for #{names.size}") unless args.size == names.size
        codes = settle(in_order(args) { value(_1) }, :none)
        names.zip(codes).map do |param, code|
          want = types[param]
          next [owned(code, want), code] if code.type == want
          next ["#{code.rust}.to_str()?", code] if code.type == T::VALUE && strings.include?(param)

          unsupported!(node, "passing #{describe(code.type)} to scope :#{scope["name"]}'s #{param} (#{describe(want)})")
        end
      end
```

In `lib/rutile/build/expressions.rb`, add:

```ruby
      # `"%#{query}%"`: format!, for the types whose Display is Ruby's
      # to_s: String, Integer, true and false.
      def interpolation(node)
        unless node.parts.all? { _1.is_a?(Prism::StringNode) || _1.is_a?(Prism::EmbeddedStatementsNode) }
          unsupported!(node, "interpolating a variable without braces")
        end
        embedded = node.parts.grep(Prism::EmbeddedStatementsNode)
        codes = in_order(embedded) { value(only(_1.statements&.body || [], _1)) }
        codes.zip(embedded).each do |code, part|
          unsupported!(part, "interpolating #{describe(code.type)}") unless [T::STR, T::INT, T::BOOL].include?(code.type)
        end
        codes = settle(codes, :none)
        template = node.parts.map { _1.is_a?(Prism::StringNode) ? _1.unescaped.gsub(/[{}]/) { |b| b * 2 } : "{}" }.join
        Code["format!(#{Names.str(template)}#{codes.map { ", #{_1.rust}" }.join})", T::STR, touch(*codes)]
      end
```

In `lib/rutile/build/translator.rb`'s `expr`, add `when Prism::InterpolatedStringNode then interpolation(node)` after the `StringNode` line.

In `lib/rutile/build.rb`, add `require_relative "build/scope_parameters"` before `require_relative "build/translator"`.

- [ ] **Step 4: Run the tests to watch them pass**

Run: `bundle exec ruby -Itest test/build/fragments_test.rb 2>&1 | tail -3`
Expected: `4 runs, ... 0 failures, 0 errors`.

- [ ] **Step 5: Run the suite and the blog regression**

Run: `bundle exec rake test 2>&1 | grep 'runs,'; bundle exec rake example:check | tail -1; bundle exec rake example:build >/dev/null && git -C ../RustOnRails status --short examples; bundle exec rake example:verify 2>&1 | grep 'runs,'; wc -l lib/rutile/build/*.rb | sort -n | tail -4`
Expected: 0 failures; `no problems`; no status lines; 17/17; every file under 300 lines.

- [ ] **Step 6: Commit**

```bash
git add lib/rutile/build/scope_parameters.rb lib/rutile/build/scopes_file.rb lib/rutile/build/queries.rb lib/rutile/build/model_calls.rb lib/rutile/build/expressions.rb lib/rutile/build/translator.rb lib/rutile/build.rb test/build/fragments_test.rb && git commit -m "rutile build: SQL fragments with binds, string interpolation, sanitize_sql_like, typed scope arguments"
```

---

### Task 7: The tracker after queries and numbers

**Files:**
- Modify: `docs/tracker-check.txt`
- Modify: `docs/gaps.md`

- [ ] **Step 1: Blog, once more**

Run: `bundle exec rake example:check | tail -1; bundle exec rake example:build >/dev/null && git -C ../RustOnRails status --short examples; (cd ../RustOnRails && cargo test --workspace 2>&1 | grep -E '^test result|^warning'); bundle exec rake example:verify 2>&1 | grep 'runs,'`
Expected: `no problems`; no status lines; all `ok` with no warnings; 17/17.

- [ ] **Step 2: Check the tracker**

Run: `EXAMPLE=tracker bundle exec rake example:check 2>&1 | grep -E '^(app/|config/|Gemfile|note: |[0-9]+ problem|no problems)' > docs/tracker-check.txt; cat docs/tracker-check.txt`
Expected: these lines are gone:
- `projects_controller.rb:7: a non-literal limit`
- `tasks_controller.rb:43: joins on Task`
- `task.rb:13: a scope parameter (query) not compared with a column`

With `set_task` compiling, the tracker's member actions (`show`, `update`, `destroy`, `complete`) are read for the first time, so new findings are expected.

- [ ] **Step 3: Update `docs/gaps.md`**

- Set the count sentence to the new total ("after plan 10"), keeping the history ("28 before plan 8, 18 after it, 15 after plan 9b").
- Under Done, add a "Plan 10 (`docs/superpowers/plans/2026-09-25-queries-and-numbers.md`)" list:
  - class-body constants;
  - `+ - *` with overflow checks;
  - `[a, b].max`, `params.fetch` and `to_i`;
  - `limit`/`offset` with any Integer;
  - `joins` along belongs_to and has_many, and `where` on a joined table;
  - SQL fragments with binds, string interpolation, `sanitize_sql_like`, and scope arguments checked against the scope's parameters.
- Remove the query API and numbers groups from Ranked and renumber. Put each newly exposed finding under the group it belongs to, or in a new group, ranked like the rest.

- [ ] **Step 4: Commit**

```bash
git add docs/tracker-check.txt docs/gaps.md && git commit -m "The tracker after queries and numbers"
```
