# What the tracker needs

[examples/tracker](../examples/tracker) is a project and task tracker written as an ordinary Rails 8 API: token auth in `ApplicationController`, `has_many :through`, several enums, numericality and scoped uniqueness, a `date` column, SQL-string scopes, member routes, pagination, `create!`/`update!` with `rescue_from RecordInvalid`. Its 16 integration tests pass on Rails (`bundle exec rake example:test EXAMPLE=tracker`). `rutile check` on it reports 28 problems ([tracker-check.txt](tracker-check.txt), 2026-09-25).

28 is a floor. Each unit (an action, a callback, a validator) reports only its first problem, and actions behind a filter that failed are skipped. The inherited `authenticate` filter fails in every controller, so most action bodies were never read. Each fix below will surface more findings until the tracker compiles.

## Ranked

Ranked by how common the construct is in Rails apps, then by how much of the tracker it unlocks. "Findings" counts lines in the report.

### 1. ApplicationController as a real base class (8 findings)

- `before_action :authenticate` inherited by every controller (3: "a before_action that isn't a method of ...").
- `attr_reader :current_user` (1) and the `current_user` calls it serves (4).
- `skip_before_action :authenticate, only: :create` needs nothing new: the manifest already records each controller's resolved filter chain.

Almost every Rails app has an auth filter and a `current_user`. Rutile: translate ApplicationController's filters and private methods into each subclass, since Rust has no inheritance and duplicating generated code is harmless. Treat `attr_reader` on an ivar as a helper that returns the field. RustOnRails: nothing. This fits the existing helper pattern, and it unblocks every action body in the tracker.

### 2. Everyday Ruby expressions (3 findings, many more hidden)

- `nil` (`where(archived_at: nil)`), `||` and `&&`, `!`, comparisons (`due_on < Date.current`), the ternary (`done? ? Time.current : nil`, reported as "if"), and `return if` guards.
- Hidden behind other failures: arithmetic (`(page - 1) * PER_PAGE`), constants (`PER_PAGE`), `[a, b].max`, and `params.fetch(:page, 1).to_i`.

Rutile: new node kinds in the translator. Each needs its truthiness and `Option` rules; `&&` and `||` return values, not booleans, when the operands aren't booleans. RustOnRails: nothing, apart from comparisons on `Option` values. This is new translator ground, but it's mechanical.

### 3. Creating and updating with attributes (2 findings, more hidden)

- `User.create!(user_params)` and `memberships.create!(user: owner, role: :admin)`.
- Hidden: `update!(archived_at: Time.current)` and `@project.update!(project_params)`.

Rutile: `create`/`create!`/`update`/`update!` on classes, records and has_many relations. The argument is either params-derived `Attributes` or a literal hash, which becomes field assignments. RustOnRails: `ctx.create_bang`-style helpers taking attributes. This extends the existing `new`/`update`/`build` pattern.

### 4. Model methods called from anywhere (hidden)

`@project.archive!`, `task.overdue?` and `@task.done!` (an enum bang method) are called from controllers, so they aren't callbacks. The tracker's model methods take no arguments, so their return types can be inferred from their bodies. Methods with parameters need the design's rbs-inline signatures (Types, layer 3). Rutile: model methods become `impl Model { pub fn ... }` taking `&mut Ctx` and a handle. Enum bang methods come from the manifest. This is a new pattern, and the core of "keep the code Rubyish".

### 5. More of the query API (3 findings, more hidden)

- `where.not(status: :done)` (reported as "0 values where one belongs"). The runtime already has `where_not`.
- A SQL fragment with binds: `where("title ILIKE ?", pattern)`. This needs `Relation::where_sql` in RustOnRails. The scope's parameter type then comes from the bind rather than a column.
- `joins(project: :memberships).where(memberships: { user_id: ... })`, which needs join SQL from association metadata.
- Hidden: `offset`, `find` on a relation (`current_user.projects.find(id)`), and `order(:due_on, :id)`.

### 6. Validators (3 findings)

- `numericality` (`only_integer`, `greater_than`, `allow_nil`) and `uniqueness: { scope: }` (2).
- RustOnRails: `Check::Numericality { .. }`, a scope on `Check::Uniqueness`, and `allow_nil`/`allow_blank` as guards. Rutile: the options map one to one. This fits the existing Check pattern.

### 7. `date` columns (1 finding)

`due_on`. RustOnRails: a `Date` type (chrono `NaiveDate`) with `FromValue`, SQL and JSON (`"2026-09-25"`), and `Date.current`. Rutile: the column type and `Date.current`.

### 8. `has_many :through` and `dependent: :nullify` (3 findings)

- `User#projects`, and `Project#members` with `source:`.
- Hidden: `project.members.include?(assignee)`.
- RustOnRails: `HasManyThrough` (a join query, preload and `include?`) and a nullify step for `dependent:`. Rutile: constants from the manifest's through and source.

### 9. Dirty-tracking conditions (1 finding)

`before_save ..., if: :will_save_change_to_status?`. RustOnRails already has `attribute_changed`. Rutile: map `will_save_change_to_x?` and `saved_change_to_x?` to it in conditions and expressions.

### 10. Rescue handlers that take the exception (1 finding)

`def invalid(error) = render json: error.record.errors, ...`. RustOnRails: `Error::RecordInvalid` carries the record's `Errors`, not only messages. Rutile: a handler parameter typed as the exception.

### 11. Blocks and hashes over records (hidden)

`tasks.map { |task| task.as_json.merge("overdue" => task.overdue?) }`. Rutile: `map` with a block over loaded records into a `Vec`, and JSON values built with `merge`. This fits closures, but blocks are new to the translator.

### 12. Model macros (3 findings)

- `has_secure_token :api_token` (2 findings: the macro and the `after_initialize` block it registers).
- `normalizes :email, with: ...`.
- `dependent: :nullify` is counted under 8.
- RustOnRails: a token generator on create, and normalization applied on assignment (Behavior entries). Rutile: map them from the class body, where the lambda is Ruby Rutile can translate.

### 13. Request headers (hidden)

`request.headers["X-Api-Token"]`. RustOnRails: `Request` keeps headers. Rutile: `request.headers[...]` as a string or nil.

## Outside what the report can show

- Verify: the proxy forwards only `Content-Type`, `Accept` and `Accept-Encoding`, so the tracker's `X-Api-Token` never reaches the Rust server. Forward every `HTTP_*` header the test sets.
- RustOnRails needs an `examples/tracker` workspace member, and `build`/`verify`/`benchmark` need to accept `EXAMPLE=tracker`. Until then they refuse.
- Runtime differences only verify can catch: JSON number and time formats for the new types, the order of error messages, and Postgres `ILIKE` against Rails' generated SQL.

## The report itself

- Inherited filters are reported without their name or line ("a before_action that isn't a method of ProjectsController"). Say `:authenticate (from ApplicationController)`.
- `where.not` reads as "0 values where one belongs", and a ternary as "if".
- "a after_initialize block" should be "an".
