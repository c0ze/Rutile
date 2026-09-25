# Model Methods and Blocks Implementation Plan (plan 11)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Status:** done. Written up after the fact, the way it was built, on branch `claude/nifty-galileo-fyhpnx` in both repos.

**Goal:** Clear the tracker's last 6 findings (gap groups 1 to 3 in `docs/gaps.md`), then run it: `rutile check` clean, the generated crate passing `cargo check`, and the tracker's 24 Rails integration tests passing against the Rust binary under verify.

**Architecture:** Each Ruby construct gets a runtime piece in RustOnRails and a translation in Rutile, as before:
- **Model macros.** `has_secure_token` and `normalizes` are resolved by Rails at boot, so introspection records what it built (manifest v3). A normalizer is the app's lambda, translated into `pub fn normalize_email(email: String) -> String` on the model. RustOnRails' `Behavior::normalizes` applies it after the type cast, on assignment and on every query value. A token on initialize is `Behavior::has_secure_token`, filled in by `Ctx::build`. On create it's a before_create hook calling `Ctx::fill_secure_token`.
- **Model methods.** A model's own instance methods become `Model::method(ctx, record)`, with return types inferred from their bodies. A registry (`ModelMethods`, one per `App`) translates each method once, so the model file emits it and callers anywhere learn its type. Enum bang methods are `update!(attr: label)`.
- **Blocks.** `relation.map { |record| ... }` loads the records once and runs the body in a `for` loop, pushing each value onto a `Vec`. A loop rather than a closure, so the body borrows the `Ctx` and uses `?` like the method around it. `merge` is Ruby's `Hash#merge` on JSON objects.
- **Verify.** The proxy forwards every header the test sets. `rake example:build` and `verify` take `EXAMPLE=tracker`, and RustOnRails gets an `examples/tracker` workspace member.

**Tech Stack:** Ruby 3.4.9 (Prism, minitest) for Rutile; Rust 2024 with the `postgres` crate (and `getrandom` for tokens) for RustOnRails.

## Global Constraints

- Keep Ruby's meaning or refuse with `Unsupported` naming `path:line`.
- Rutile files stay under 300 lines. RustOnRails and generated code build with zero warnings.
- Blog regression after every Rutile task: `rake example:check` prints `no problems`, `rake example:build` leaves `git -C ../RustOnRails status --short examples` empty, and `rake example:verify` passes 17/17.

## Review Focus

1. **Normalization everywhere Rails applies it.** Assignment from params or a hash, typed writes in generated code (`self.email = ...`, `||=`, `create!(email: ...)`), and every query value (`where`, `where.not`, `where(email: [...])`, a joined table's `where`, `find_by`, and the uniqueness check). Nil is never passed to the normalizer. Tests: `normalization_test.rs`, `model_macros_test.rb#test_writes_to_a_normalized_attribute_normalize`, and the tracker's "an email that's taken is a 422" under verify.
2. **Tokens only where Rails makes them.** A new record without a token gets 24 base58 characters when built. A given token is kept and a blank one replaced, as `query_attribute` reads a String. A loaded record never gets one. `on: :create` waits for the INSERT and leaves updates alone. Test: `secure_token_test.rs`.
3. **Method lookup as Ruby does it.** The model's own method wins over a column, association or Rails method of the same name. Only the record itself calls a private method. A method redefining an enum method, shadowing one of `Model`'s associated functions, taking parameters, or calling itself is refused. So is calling a callback method from elsewhere. Test: `model_methods_test.rb`.
4. **Blocks keep Ruby's scoping.** A local first assigned in the block doesn't exist after it; `return` inside the block is refused; the records load once. Test: `blocks_test.rb`.
5. **merge only on hashes.** Only on what `as_json` of one record or a hash literal gives, since `as_json` of a relation is an array. Test: `blocks_test.rb#test_merge_on_a_hash_as_json_or_a_literal_made`.

---

### Task 1: RustOnRails — tokens, normalization, merge

**Files:** `src/secure_token.rs` and `src/normalization.rs` (new), `src/behavior.rs`, `src/records.rs` (`build`), `src/model.rs` (`assign_to`), `src/relation.rs` and `src/relation/sql.rs` (`query_value`), `src/json.rs` (`merge`), `Cargo.toml` (`getrandom`). Tests: `tests/secure_token_test.rs`, `tests/normalization_test.rs`, `tests/merge_test.rs`.

- [x] `base58(length)`: uniform over ActiveSupport's alphabet, redrawing the 6 of 64 byte values that don't fit.
- [x] `Behavior::has_secure_token(attribute, length)`, applied in `Ctx::build` to a blank attribute; `Ctx::fill_secure_token` for `on: :create`.
- [x] `Behavior::normalizes(attribute, fn(String) -> String)`, applied after the cast in `assign_to` and in `Behavior::query_value` (cast, normalize, then enum label to integer).
- [x] `merge(base, other)`: `Hash#merge` on two objects. A key already present keeps its place.

### Task 2: Introspection — manifest v3

**Files:** `lib/rutile/introspect/models.rb` (`normalizations`), `lib/rutile/introspect/callbacks.rb` (the token block's closure), `lib/rutile/introspect/manifest.rb` (version 3), `docs/manifest.md`. Test: `test/introspect/model_macros_test.rb`.

- [x] `"normalizations": {"email": {"with": {"proc": <location>}, "apply_to_nil": false}}` from `normalized_attributes` and each attribute's `NormalizedValueType`.
- [x] A framework block from `active_record/secure_token.rb` carries `"secure_token": {"attribute", "length"}`, read from the block's binding.

### Task 3: Rutile — normalizes and has_secure_token

**Files:** `lib/rutile/build/model_macros.rb` (new), `behavior.rb`, `model_file.rb`, `declarations.rb`, `model_calls.rb` (`assigned`), `translator.rb` (`||=`). Test: `test/build/model_macros_test.rb`.

- [x] The normalizer lambda as a function on the model, translated with no `self` and no database. It must return a String and can't fail, since query values have no error path.
- [x] Refused: `apply_to_nil`, a normalizer that isn't a lambda in the app, and a normalized attribute that isn't a String column, is an enum, or is a belongs_to key.
- [x] Typed writes to a normalized attribute call the normalizer (`Some(User::normalize_email(...))`, `.map(User::normalize_email)`).
- [x] Tokens: `.has_secure_token(...)` for initialize, `.before_create(|ctx, user| ctx.fill_secure_token(...))` in its chain slot for create.

### Task 4: Rutile — model methods and enum bang methods

**Files:** `lib/rutile/build/model_methods.rb` and `record_methods.rb` (new), `app.rb` (`enum_bang`, `model_methods`), `types.rb` (`Uses#merge`), `model_file.rb`. Test: `test/build/model_methods_test.rb`.

- [x] Every public method is compiled as `pub fn`, and a private one when its record calls it. Visibility follows `private`, `private def` and `private :name` in the class body.
- [x] Return types come from the body: any type with a Rust spelling, or `()`.
- [x] `@project.archive!` from a controller is `Project::archive_bang(&mut req.ctx, project)?`.
- [x] `task.done!` is `task.status = "done"; save!`.

### Task 5: Rutile — map blocks, merge, rendering lists

**Files:** `lib/rutile/build/blocks.rb` (new), `translator.rb`, `types.rb` (`T.list`), `web_calls.rb` (`object:` Codes, `render json:` of a list). Test: `test/build/blocks_test.rb`.

- [x] `map` with one plain block parameter over a relation; elements may be JSON, String, Integer, true/false or records (possibly nil for the scalars).
- [x] `render json:` of a list: `Json::Array` of hashes, `render_all` of records, `Json::from` of scalars.

### Task 6: Verify the tracker

**Files:** `lib/rutile/verify/target.rb`, `rakelib/example.rake`, `../RustOnRails/Cargo.toml`, `../RustOnRails/examples/tracker/` (generated). Test: `test/verify/target_test.rb#test_forwards_every_header_the_test_sets`.

- [x] `bundle exec rake example:check EXAMPLE=tracker` prints `no problems`.
- [x] `bundle exec rake example:verify EXAMPLE=tracker` passes 24/24. Pointed at a dead port, the same tests all error, so they did reach the Rust server.
