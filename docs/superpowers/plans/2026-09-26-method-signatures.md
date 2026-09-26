# Methods with parameters (0.6.0)

A record of the milestone rather than a plan to follow: what `feature/method-signatures` built, what its adversarial review found, and how each finding was settled.

**Goal:** Model methods and controller helpers with parameters compile, typed by rbs-inline comments, and calls pass them checked arguments; a missing or wrong signature is refused with its location (roadmap 0.6.0).

**Architecture:** `Signatures` reads the comment lines directly above a def (`#: (Integer) -> Post?`, `# @rbs (…) -> …`, `# @rbs name: T`, `# @rbs return: T`) with the `rbs` gem's parser and maps each RBS type to what generated code holds: scalars, models, relations, `Array[T]`, `bool`, `T?`, `void`. `Arguments` matches a call's arguments to the parameters (positional, then keywords by name), evaluates them in Ruby's order, converts each to its parameter's type and fills literal defaults. `ModelMethods` and `ControllerFile` declare the parameters on the translator and emit them after `ctx`/`req`; a declared return type checks the method's value and turns it into `Some` where it may be nil.

**Example:** `examples/store`, a Rails 8.1 API (products, orders, line items) whose models and controllers use every signature form. Its 9 integration tests pass on Rails and on the Rust build.

## The review

An agent reviewed the branch adversarially against snapshots of both repos, building each probe with `rutile build` and `cargo check`. Its findings, most severe first, and what became of them:

| # | Finding | Settled |
|---|---|---|
| 1 | An instance variable passed as an argument, or a call's receiver, was read after a later argument's helper call, which can reassign it | `in_order` and `after` bind instance-variable reads before statements or a helper call (`Borrowing#stale?`) |
| 2 | A Symbol literal passed where `String` is declared, or returned as one, compared equal to the String | Refused: passing or returning a Symbol as a String, `==` between the two, String methods on a Symbol (`to_s` excepted), a Symbol in a local assigned twice |
| 3 | A param value passed where `String` is declared was converted with `to_str()?`, raising on nil or a number where Ruby passes it on | Refused; `params[:x].to_s` makes it a String, as in Ruby |
| 4 | An argument that can fail but doesn't touch the Ctx ran after a later argument's write | `in_order` binds earlier fallible codes too; keywords given out of the def's order bind what can fail, so it fails in the order written |
| 5 | Recursion compiled without a depth guard: Ruby's SystemStackError is a 500, a Rust stack overflow aborts the server | Recursion is refused, direct or mutual, signature or not |
| 6a | An unused parameter named like a field (`self.stock`) counted as used, so Rust warned | `Names.mentions?` skips a name right after `.` (not `..`) |
| 6b | A parameter named `_` can't be read in Rust | Named `_arg` |
| 6c | Two parameters with one underscore name (`_x, _x`), which Ruby allows | Refused |
| 6d | A parameter or local named like a runtime function (`now`, `merge`, …) shadowed it | `Names::FUNCTIONS` joins the reserved names for parameters and locals |
| 6e | A `-> void` method ending in `nil` (or `stock + 1`) emitted a statement Rust rejects or warns about | A statement that can neither fail nor write isn't emitted |
| 6f | A keyword given twice left its first value unused | Refused |
| 6g | An Integer literal (or default) beyond 64 bits | Refused where it's written |
| 7 | A destructuring parameter crashed `rutile check` | Refused |
| 8 | `public_send` reached a private method | Refused, as Ruby raises |
| 9 | A Float default was accepted, then failed at the call with the caller's path | Float literals compile |
| 10 | Trailing text after a type, overloads and `#|` lines were misread rather than refused; a trailing comment on the line above counted | `require_eof: true`; a second method type is refused as an overload; `#|` isn't RBS syntax, so it isn't read; trailing comments are skipped |
| 11 | Does a nil receiver fare worse? | No. The case that matters predates the branch and is listed in `gaps.md` |
| 13 | Test gaps | Each fix above has a test |

## Verification

- `bundle exec rake test`: 292 runs, no failures.
- `rake example:verify` for the blog (17), the tracker (24) and the store (9): every integration test passes against the Rust build. The regenerated blog and tracker crates are unchanged; the store's `restock` now reads `@product` before calling the `amount` helper.
