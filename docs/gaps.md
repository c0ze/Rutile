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

- **Methods that call themselves**, directly or through another. Ruby stops a runaway recursion with SystemStackError; a Rust stack overflow would abort the server. (Methods with parameters compile since 0.6.0, typed by rbs-inline signatures.)
- **Blocks with more than one parameter** (`each_with_index`, `each_with_object`, hashes), `any?`/`all?`/`count` with a block, `min`/`max`/`average` of an array, `/` and `%`. (`each`, `select`, `reject`, `sum`, `find_each`, `map(&:name)`, `it` and `_1`, aggregates and transactions compile since 0.7.0.)
- **Callbacks**: `after_initialize` and `after_find` blocks or methods of the app's own; `saved_change_to_x?` (the runtime keeps the changes a save will make, not those it made); callback conditions naming an app method.
- **Normalizers** on columns other than strings, with `apply_to_nil`, more than one on an attribute, with `it` or numbered parameters, or ones that could fail.
- **Methods Rails itself calls**: a model method replacing one of Active Record's (`destroy`, `readonly?`, `self.generate_unique_secure_token`), or a column's or association's reader. Rutile only controls its own call sites, so RustOnRails would call its own.
- **A `rescue` or `ensure` around a whole method body**, and enum methods renamed by `prefix:` or `suffix:`.
- **Hashes** anywhere but a literal rendered as JSON or merged into `as_json`: reading keys back, `as_json` of a relation then `merge`, or a String and a Symbol key of the same name in one hash, which Rails' JSON encoder raises on.
- **A benchmark for the tracker.** `rake example:benchmark` stays blog-only: loadgen sends no headers, and every tracker route but sign-up wants a token.

## Runtime differences only verify can catch

- The Value fallback raises where Ruby would go on for a few operations it doesn't carry out: `Date - Date` (a Rational in Ruby), `Date + 1.5`, and `String#%` (Ruby's `format`).

- An association doesn't keep the children built on it: `order.line_items.build(...)` then `order.line_items.size` counts the saved rows only, where Rails adds the unsaved one.
- `find_each` queries one batch at a time, but the records it loads stay in the request's `Ctx` until the request ends, since a handle into them may live on.
- Two locals naming one relation (`b = a`) are two copies here: loading one doesn't load the other, where in Ruby they are one object.

- The tracker's tests exercise the JSON formats of dates and times, error message order, `ILIKE` against Rails' SQL, token length and email normalization, and they pass. Other apps will exercise more.
- `record.update!(attributes)` on a nil record reads the record before the attributes, so with `@product` nil and the params missing, Rust answers 500 (NoMethodError) where Rails answers 400 (ParameterMissing). Both are errors; only the status differs.
- Where RustOnRails doesn't copy Rails, it fails rather than guess: a date string in a format only `Date._parse` reads is a cast error (a 500), not a date or nil. One case stays silent: after params assign a numeric column a value that isn't an integer ("1.5"), app code writing back exactly its cast (1) leaves numericality checking "1.5", where Rails checks 1.
