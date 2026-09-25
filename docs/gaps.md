# What the tracker needs

[examples/tracker](../examples/tracker) is a project and task tracker written as an ordinary Rails 8 API: token auth in `ApplicationController`, `has_many :through`, several enums, numericality and scoped uniqueness, a `date` column, SQL-string scopes, member routes, pagination, `create!`/`update!` with `rescue_from RecordInvalid`. Its 24 integration tests pass on Rails (`bundle exec rake example:test EXAMPLE=tracker`).

`rutile check` on it reports 8 problems ([tracker-check.txt](tracker-check.txt), after plan 9a): 28 before plan 8, 18 after it, 15 after plan 9b. The count is a floor. Each unit reports only its first problem, and actions behind a failed filter are skipped. Each fix below surfaces more findings until the tracker compiles.

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

Plan 9a (branch `tracker-gaps-2a`):

- Validators: `numericality` with `only_integer` and the six comparisons, `uniqueness: { scope: }`, and `allow_nil`/`allow_blank` on any validator, with Rails 8.1's messages. RustOnRails keeps each attribute's value as assigned until a save, because numericality checks that value ("1.5" isn't an integer though the column holds 1), and parses and compares it the way Active Model does. Options that name a method or a lambda are refused.
- `date` columns: RustOnRails' `Date` casts, reads, writes and renders as Rails does; `Date.current` (UTC only) and `Date.today`; dates compare with the ordering operators.
- `will_save_change_to_x?` in callback conditions and expressions is `attribute_changed`, which now also counts a number replaced by a non-number as Active Model does. `saved_change_to_x?` is refused: the runtime doesn't keep the last save's changes.
- Rescue handlers that take the exception: RustOnRails' `RecordInvalid` carries the record's errors, so `error.record.errors` renders as in Rails. Other uses of the exception, and other exceptions, are refused.
- `dependent: :nullify`: `HasMany::nullify_all`, one `UPDATE` in the before_destroy slot Rails uses.
- No new findings surfaced behind these.

## Ranked

Ranked by how common the construct is in Rails apps, then by how much of the tracker it unlocks. "Findings" counts lines in the report.

### 1. Model macros (3 findings)

- `has_secure_token :api_token`, which is 2 findings: the macro, and the `after_initialize` block it registers.
- `normalizes :email, with: ...`.
- RustOnRails: a token generator on create, and normalization applied on assignment (Behavior entries). Rutile: map them from the class body; the `with:` lambda is Ruby Rutile can translate.

### 2. The query API (2 findings, more hidden)

- `joins(project: :memberships).where(memberships: { user_id: ... })`, which needs join SQL from association metadata. RustOnRails' `join_through` covers one hop; this is two.
- A SQL fragment with binds: `where("title ILIKE ?", "%#{sanitize_sql_like(query)}%")`. This needs `Relation::where_sql` and string interpolation; the scope's parameter type comes from the bind.
- Hidden: `offset`.

### 3. Model methods called from anywhere (1 finding, more hidden)

`@project.archive!`, `task.overdue?` and `@task.done!` (an enum bang method) are called from controllers, so they aren't callbacks. The tracker's methods take no arguments, so their return types can be inferred from their bodies. Methods with arguments need the design's rbs-inline signatures (Types, layer 3). Rutile: model methods become `impl Model { pub fn ... }` taking `&mut Ctx` and a handle. Enum bang methods come from the manifest. `overdue?` compares dates, which now compile.

### 4. Numbers, constants and small helpers (1 finding, more hidden)

`limit(PER_PAGE)` is the finding. Behind it: `(page - 1) * PER_PAGE`, `[a, b].max`, and `params.fetch(:page, 1).to_i`. Ruby integers don't overflow; the design wants checked i64 arithmetic that fails loudly. Rutile: arithmetic on `INT`/`FLOAT` through checked helpers, and class constants as Rust `const`s.

### 5. Blocks and hashes over records (1 finding)

`tasks.map { |task| task.as_json.merge("overdue" => task.overdue?) }`. Rutile: `map` with a block over loaded records into a `Vec`, and JSON values built with `merge`.

## Outside what the report can show

- Verify: the proxy forwards only `Content-Type`, `Accept` and `Accept-Encoding`, so the tracker's `X-Api-Token` never reaches the Rust server. Forward every `HTTP_*` header the test sets.
- RustOnRails needs an `examples/tracker` workspace member, and `build`/`verify`/`benchmark` need to accept `EXAMPLE=tracker`. Until then they refuse.
- Runtime differences only verify can catch: JSON formats for the new types, the order of error messages, and Postgres `ILIKE` against Rails' generated SQL.
- Where RustOnRails doesn't copy Rails, it fails rather than guess: a date string in a format only `Date._parse` reads is a cast error (a 500), not a date or nil. One case stays silent: after params assign a numeric column a value that isn't an integer ("1.5"), app code writing back exactly its cast (1) leaves numericality checking "1.5", where Rails checks 1.
