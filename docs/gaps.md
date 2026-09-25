# What the tracker needed

[examples/tracker](../examples/tracker) is a project and task tracker written as an ordinary Rails 8 API: token auth in `ApplicationController`, `has_many :through`, several enums, numericality and scoped uniqueness, a `date` column, SQL-string scopes, member routes, pagination, `create!`/`update!` with `rescue_from RecordInvalid`. Its 24 integration tests pass on Rails (`bundle exec rake example:test EXAMPLE=tracker`).

Since plan 11 they pass on Rust too: `rutile check` reports no problems ([tracker-check.txt](tracker-check.txt)), `bundle exec rake example:build EXAMPLE=tracker` generates `RustOnRails/examples/tracker`, and `bundle exec rake example:verify EXAMPLE=tracker` runs all 24 integration tests against it. The report went from 28 problems before plan 8 to 18 after it, 15 after plan 9b, 6 after plans 9a and 10, and none after plan 11. The tracker was written as a Rails app first, not for Rutile, so this list is what one ordinary app needed.

## Done

Plan 8 (`docs/superpowers/plans/2026-09-25-tracker-gaps-1.md`):

- ApplicationController's filters, private methods and `attr_reader`s now reach every controller. A filter that renders halts the chain, and `skip_before_action` follows the manifest's chain.
- Everyday expressions: `nil`, `&&`, `||`, `!`, comparisons, the ternary, and `return` in callbacks and filters.
- `create`/`create!`/`update`/`update!` take params-derived attributes or a literal hash.
- `where.not`.
- `request.headers[...]` (RustOnRails keeps request headers).
- The report names inherited filters, and calls through an association the model file refuses are refused as well.

Plan 9b (`docs/superpowers/plans/2026-09-25-has-many-through.md`):

- `has_many :through`, with `source:`: `User#projects` and `Project#members`. RustOnRails' `HasManyThrough<M, T>` builds an inner join on the join table; Rutile makes the constant from the two associations it chains.
- `find` and `include?` on any relation.
- `set_project` and `set_task`'s finder now pass, which exposed three findings further down the tracker's actions (`limit(PER_PAGE)`, `archive!`, `map` with a block).

Plan 9a (branch `tracker-gaps-2a`, built by an agent from a brief; no plan file):

- Validators: `numericality` with `only_integer` and the six comparisons, `uniqueness: { scope: }`, and `allow_nil`/`allow_blank` on any validator, with Rails 8.1's messages. RustOnRails keeps each attribute's value as assigned until a save, because numericality checks that value ("1.5" isn't an integer though the column holds 1), and parses and compares it the way Active Model does. Options that name a method or a lambda are refused.
- `date` columns: RustOnRails' `Date` casts, reads, writes and renders as Rails does; `Date.current` (UTC only) and `Date.today`; dates compare with the ordering operators.
- `will_save_change_to_x?` in callback conditions and expressions is `attribute_changed`, which now also counts a number replaced by a non-number as Active Model does. `saved_change_to_x?` is refused: the runtime doesn't keep the last save's changes.
- Rescue handlers that take the exception: RustOnRails' `RecordInvalid` carries the record's errors, so `error.record.errors` renders as in Rails. Other uses of the exception, and other exceptions, are refused.
- `dependent: :nullify`: `HasMany::nullify_all`, one `UPDATE` in the before_destroy slot Rails uses.
- No new findings surfaced behind these.

Plan 10 (`docs/superpowers/plans/2026-09-25-queries-and-numbers.md`):

- Class-body constants become Rust `const`s, looked up as Ruby does: the method's own class, then ApplicationController or ApplicationRecord.
- `+`, `-` and `*` on Integers and Floats. Generated crates build with `overflow-checks` in release too, so an overflow is a 500 where Ruby would make a Bignum, never a wrapped number.
- `[a, b].max` and `.min`, `params.fetch(:key, default)`, and `to_i` with Ruby's parsing.
- `limit` and `offset` with any Integer expression.
- `joins` along belongs_to and has_many, and `where` on a joined table's columns (including a has_many :through's join table).
- SQL fragments with `?` binds, string interpolation, and `sanitize_sql_like`. A scope's arguments are checked against its parameters; a param value passed where a String is wanted must be one.
- `set_task` now compiles, so the member actions behind it are read: `complete` exposed `done!`.

Plan 11 (`docs/superpowers/plans/2026-09-25-model-methods-and-blocks.md`):

- `has_secure_token` and `normalizes`, as Rails builds them at boot (manifest v3). A normalizer is the app's lambda translated into a function on the model; RustOnRails applies it after the type cast, on assignment and to every query value, as Active Model's `NormalizedValueType` does. A token is generated when a record is built, or before create with `on: :create`.
- A model's own methods (`archive!`, `overdue?`) become functions on the model taking the `Ctx` and the record, with return types inferred from their bodies. Every public one is compiled; a private one when its record calls it. Enum bang methods (`done!`) are `update!(status: :done)`.
- `relation.map { |record| ... }` compiles to a loop into a `Vec`; `render json:` renders the list. `merge` works on a hash `as_json` or a literal made.
- Verify forwards every header the test sets, so `X-Api-Token` reaches the Rust server. `build` and `verify` accept `EXAMPLE=tracker`, and the tracker is a RustOnRails workspace member.
- Nothing new surfaced behind these: once `rutile check` was clean the crate compiled, and all 24 integration tests passed on the first verify run.

## What's refused that the next app will want

Each of these is refused with the file and line rather than compiled wrong. They're the constructs this round met and left for later, roughly in the order a typical Rails app would hit them.

- **Methods with parameters**, on models and in controllers. They need the design's rbs-inline signatures (Types, layer 3); inferring from call sites would be whole-program inference.
- **Blocks other than `map` over a relation**: `each`, `select`, `sum`, `find_each`, `map(&:name)`, numbered and `it` parameters, and `map` over a list `map` returned.
- **Callbacks**: `after_initialize` and `after_find` blocks or methods of the app's own; `saved_change_to_x?` (the runtime keeps the changes a save will make, not those it made); callback conditions naming an app method.
- **Normalizers** on columns other than strings, with `apply_to_nil`, or ones that could fail.
- **Hashes** anywhere but a literal rendered as JSON or merged into `as_json`: reading keys back, symbol-keyed hashes as values, `as_json` of a relation then `merge`.
- **A benchmark for the tracker.** `rake example:benchmark` stays blog-only: loadgen sends no headers, and every tracker route but sign-up wants a token.

## Runtime differences only verify can catch

- The tracker's tests exercise the JSON formats of dates and times, error message order, `ILIKE` against Rails' SQL, token length and email normalization, and they pass. Other apps will exercise more.
- Where RustOnRails doesn't copy Rails, it fails rather than guess: a date string in a format only `Date._parse` reads is a cast error (a 500), not a date or nil. One case stays silent: after params assign a numeric column a value that isn't an integer ("1.5"), app code writing back exactly its cast (1) leaves numericality checking "1.5", where Rails checks 1.
