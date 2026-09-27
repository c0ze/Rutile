# Limitations

What Rutile refuses today, and what compiles with a known difference. The source lists are [gaps.md](../gaps.md) and [open-items.md](../open-items.md) in this repository, and [open-items.md](https://github.com/c0ze/RustOnRails/blob/main/docs/open-items.md) in RustOnRails.

## The principle

Anything that would behave differently is refused rather than compiled. A Rails app's tests pass on Rails; if the binary behaved differently on some input, the tests might not notice, and production would. So when Rutile can't give a construct Rails' behavior, it stops with the file, the line and what it can't do:

```
app/views/storefront/index.html.erb:1: the helper amount in a view isn't supported yet
config/routes.rb: force_ssl without assume_ssl (redirecting plain HTTP) isn't supported yet
app/jobs/restock_job.rb: RestockJob with enqueue_after_transaction_commit isn't supported yet
```

`rutile build` stops at the first refusal and leaves the previous crate as it was. `rutile check` reports every one at once ([Commands](Commands.md)).

Where the runtime doesn't copy Rails, it fails rather than guesses: a date string in a format only `Date._parse` reads is a cast error (a 500), not a date or nil. The few differences that do compile are listed at the end of this page.

## The Ruby subset

`eval`, `method_missing`, `send` with a computed name, `define_method`, reopened core classes, class variables and mutable globals are rejected on sight. See [The Ruby Subset](The-Ruby-Subset.md).

Only files directly in `app/models`, `app/controllers` and `app/jobs`, the templates in `app/views`, and `config/routes.rb` are compiled. Other files under `app/` (helpers, concerns, services, subdirectories) are noted by `rutile check`; a call into them is refused.

Gems that change Rails at runtime (activeadmin, rails_admin, paper_trail, ransack, devise) are problems for `rutile check`: keep those parts on a Rails sidecar, or rewrite them. Gems only in the development or test groups are skipped, as are the ones that never reach compiled code (`rails`, `pg`, `puma`, `bootsnap`, `tzinfo-data`, `thruster`, `kamal`, `propshaft`) and `sidekiq`, whose protocol the binary speaks. Any other gem is a note, and any use of it the build can't compile is refused.

## Configuration

- A time zone other than UTC (`config.time_zone`, `active_record.default_timezone`).
- A default locale other than `en`, and locale files that reword validation messages. The runtime writes Rails' English messages.

## Models

- Single-table inheritance, optimistic locking, a primary key other than `id`, and namespaced models.
- Defaults set in the model (`enum ..., default:`, `attribute ..., default:`).
- `has_one`, `has_and_belongs_to_many`, and `has_many :through` in any shape but through a `has_many` to a `belongs_to` on the join model.
- Enums with values other than integers, and enum methods renamed by `prefix:` or `suffix:`.
- `around_*` callbacks, and callbacks on events other than validation, save, create, update and destroy: `after_initialize`, `after_find`, `after_commit` and the rest (`has_secure_token`'s own is the exception).
- Callback conditions naming an app method, and `saved_change_to_x?`: the runtime keeps the changes a save will make, not those it made.
- Validator options that name a method or a lambda, and validators beyond the common ones.
- Normalizers on columns other than strings, with `apply_to_nil`, more than one on an attribute, or ones that could fail.
- A model method replacing one of Active Record's (`destroy`, `readonly?`) or a column's or association's reader: Rails calls its own methods, which Rutile doesn't control.
- A method calling itself, directly or through another. Ruby stops a runaway recursion with `SystemStackError`; a Rust stack overflow would abort the server.

See [Models](Models.md).

## Queries

- `where` ranges other than `x..`, and ranges on a joined table.
- `find_each` with options other than `batch_size:`.
- `transaction` with options (`requires_new: true`).
- An array or a hash param read as a single value: `?status[]=todo&status[]=doing` read as `params[:status]` is a 500, since a `Value` holds scalars only, where Rails filters with `IN`. This one is on hold in both repositories, waiting on arrays in `Value`.

See [Queries](Queries.md).

## Controllers and routes

- Routes to a redirect or a mounted app, with `requirements`, request constraints (other than a lambda taking the request) or `via: :all`, to a namespaced controller, or to an action a controller inherits.
- An action that doesn't end in `render` or `head`, or renders or heads anywhere but at its end, unless it renders its template ([Views](Views.md)).
- Calling a `before_action` that renders from another method: its response would be lost.
- `rescue_from` for exceptions other than `RecordNotFound`, `RecordInvalid`, `RecordNotSaved`, `RecordNotDestroyed` and `ParameterMissing`, with a block, or with a handler outside the controller and `ApplicationController`.
- `wrap_parameters` for formats other than JSON, and with `exclude:`. The wrapper name and `include:` list Rails recorded compile, and so does wrapping turned off.

See [Controllers and Routes](Controllers-and-Routes.md).

## Ruby in method bodies

- `elsif` and `case`. Use nested `if`/`else`.
- A `rescue` or `ensure` around a whole method body or a block's body; `raise` other than `raise ActiveRecord::Rollback`.
- Blocks with more than one parameter (`each_with_index`, `each_with_object`, blocks over hashes), and `any?`, `all?` and `count` with a block.
- `average` of an array, and `min` and `max` of anything but a non-empty array literal of Integers (`[a, b].max`).
- Hashes anywhere but a literal rendered as JSON or merged into `as_json`: reading keys back, or a String and a Symbol key of the same name in one hash, which Rails' JSON encoder raises on.
- A Symbol compared with a String, which Ruby says is never equal.
- Methods with parameters and no rbs-inline signature; overloads; splats and block parameters.

See [Ruby Features](Ruby-Features.md), [Types and Signatures](Types-and-Signatures.md) and [Value Fallback](Value-Fallback.md).

## Sessions and cookies

- Session stores other than the cookie store.
- The session cookie's `domain:` and `expire_after:`, and a cookie format other than Rails 8's default (serializer, cipher, salt, metadata, rotations, key digest).
- Records, arrays, hashes and Symbols as session values.
- Signed and encrypted cookie jars, options on plain cookies, and `flash`.
- SameSite decided per request.

See [Sessions and Cookies](Sessions-and-Cookies.md).

## Jobs

- Queue adapters other than Sidekiq, and plain `Sidekiq::Job` classes.
- `retry_on`, `discard_on`, `sidekiq_options` and job callbacks, in the job or in `ApplicationJob`.
- `enqueue_after_transaction_commit`, `queue_name_prefix`, namespaced job classes, and a queue a block chooses.
- `set(wait:)` and other `set` calls in the binary; the worker still runs jobs Rails scheduled.
- Arguments other than records, Integers, Floats, Strings, booleans and nil.

See [Jobs](Jobs.md).

## Views

- Partials and collection rendering.
- Helpers that take a block (`form_with`, `link_to ... do`).
- Action View helpers other than `link_to`, `content_for`, `provide`, `content_for?`, `raw` and the `_path` helpers, and the app's own `app/helpers`.
- `_url` helpers and `redirect_to`.
- Templates in other formats or handlers.
- A layout a method or a condition chooses.
- A non-GET route to an `ActionController::Base` controller that keeps Rails' forgery-protection filters, which would need the form's token.

See [Views](Views.md).

## Middleware

- `force_ssl` without `assume_ssl`, which would redirect plain HTTP.
- `ssl_options` other than Rails' defaults.

See [Middleware and Errors](Middleware-and-Errors.md).

## Compiles with a known difference

These compile, and behave differently from Rails in the way described. The app's own tests, run under `rutile verify`, are what catches them.

**Values and types**

- The Value fallback raises where Ruby would go on for a few operations: `Date - Date` (a Rational in Ruby), `Date ± 1.5`, `String#%` (Ruby's `format`), and a Date or Time past chrono's range (about ±262,000 years), which Ruby's reaches.
- `Time + Float` keeps microseconds, so a fraction of a microsecond rounds where Ruby's Rational time wouldn't.
- After params assign a numeric column a value that isn't an integer (`"1.5"`), app code writing back exactly its cast (`1`) leaves numericality checking `"1.5"`, where Rails checks `1`.
- `record.update!(attributes)` on a nil record reads the record before the attributes, so with the record nil and the params missing, the binary answers 500 (NoMethodError) where Rails answers 400 (ParameterMissing).

**Records and relations**

- An association doesn't keep the children built on it: `order.line_items.build(...)` then `order.line_items.size` counts the saved rows only, where Rails adds the unsaved one.
- Two locals naming one relation (`b = a`) are two copies: loading one doesn't load the other, where in Ruby they are one object.
- `find_each` queries one batch at a time, but the records it loads stay in the request's `Ctx` until the request ends ([Runtime](Runtime.md)).

**HTTP**

- Responses carry Rails' default headers, `Vary: Accept` and, under `force_ssl`, HSTS, but not Rack's `ETag` and `Cache-Control`, so a conditional GET is never a 304. `rutile verify` doesn't compare with Rails: it hands the binary's responses, headers included, to the app's integration tests, so it catches a difference only where they assert on it.
- After Postgres restarts, each worker's first request that touches the database fails with a 500 before the worker reconnects. Rails 7.1 and later reconnect and retry an idempotent read.
- `OPTIONS *` and absolute-form targets (`GET http://host/path`) are refused with a 400; RFC 9112 asks servers to accept the absolute form. A bare LF after chunk data is accepted where RFC 9112 wants CRLF.
- Bodies in flight are bounded per connection only, and the body deadline's credit is earned up front ([Runtime](Runtime.md#limits)).

**Views and jobs**

- A template compiles as Rails compiled it in the environment introspected, so a build introspected in development carries `annotate_rendered_view_with_filenames` comments if that environment turns them on.
- The Rust worker runs every Active Job payload on the queues it's given; a class the build doesn't have fails into Sidekiq's retry set, where a Ruby worker may take it later.

**Tooling**

- `rutile verify` runs `test/integration` unless `--test` names other paths. Only integration tests' requests reach the binary: model tests call the Ruby models in the test's own process, so there's nothing to forward.
- `rutile check`'s source rules are static. They follow the app's constants as Ruby binds them, but Ruby can still patch a class in ways no reading of the source settles (`Object.const_set`, a constant bound in a file loaded later, patches inside methods that run at boot). The build refuses what the rules report; it can't refuse what they miss.
- A regexp Rust can't parse (a `\p{...}` name Rust doesn't know) still passes `rutile build`, since `cargo check` doesn't parse regexps. The server builds every model's validations when it starts, so it stops there, naming the model's file.

RustOnRails' [open-items.md](https://github.com/c0ze/RustOnRails/blob/main/docs/open-items.md) lists smaller Rails-parity gaps in the runtime.
