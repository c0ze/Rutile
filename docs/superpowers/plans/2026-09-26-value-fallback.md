# The Value fallback (0.8.0)

This records what `feature/value-fallback` built, what its adversarial review found, and how each finding was settled.

**Goal:** Code that failed only because no static type reached a value compiles to `Value` operations with Ruby's semantics, and `rutile build` lists each place it fell back (roadmap 0.8.0).

**Architecture:**

- **Runtime (RustOnRails):**
  - `dynamic.rs` gives `Value` Ruby's operators: `+ - * / %`, `==`, the orderings, truthiness and `to_s`. Each one dispatches on the classes it's handed, with Ruby's results and Ruby's TypeError, ArgumentError, NoMethodError and ZeroDivisionError messages.
  - `div_integers`, `mod_integers` and `mod_floats` are Ruby's floored `/` and `%` for the static types.
- **Compiler (Rutile):**
  - `Dynamic` decides where a Value goes: a param, an `untyped` signature, a local given values of two classes, an `if` whose branches differ, or a method without a signature that returns two classes.
  - A local or a return type found to need a Value raises `Retype`, and the body is translated again with it retyped (`retyped`).
  - Each fallback is recorded with its location. `rutile build` prints them, and `rutile check` lists them as notes.

**Example:** the store gains `double`, `availability` and `tag_with`. Its 20 integration tests pass on Rails and on the Rust build.

## The review

An agent reviewed the branch adversarially. It did four things:

- built each suspect snippet and ran `cargo check` on it;
- sent the same requests to Rails 8.1 and the Rust build, and compared the bodies;
- probed the translator;
- ran `ruby -e` / `bin/rails runner` for Ruby's own answers.

| # | Finding | Settled |
|---|---|---|
| 1 | A JSON key ending in `r` (`{ order: params[:order] }`) hid `req` from the signature: `code_only` read `r"` inside `"order"` as a raw string | `code_only` strips string and raw-string literals in one left-to-right pass, and only an `r` that starts a token opens a raw string |
| 2 | A retry dropped the imports of a helper translated during the failed attempt | The controller checkpoints its helpers and instance variables at each body. A retry rolls them back in place, so the helper is translated again with its imports |
| 3 | `return` in a normalizer, route constraint or scope lambda emitted `return Ok(...)` | A body that doesn't return a `Result` returns the bare value |
| 4 | `Retype` escaped and crashed `build` and `check`: a Symbol reassigned, a ternary as a transaction block's value, or more than 20 retyped locals | A Symbol given to a local of another class is refused. A block's `if` can't retype the method's return. A local already retyped can't be retyped again. The attempts are bounded by the number of locals, and running out raises Unsupported with the line |
| 5 | Interpolating a nilable String local moved it | `as_deref().unwrap_or_default()` |
| 6 | A Value local used as a ternary branch was moved | `dynamic_unify` clones a local it reads |
| 7 | `Option<Value>` counted a held nil or false as present | nil and a Value make a Value (which holds nil itself), for inferred returns and for `c ? nil : params[:a]` alike |
| 8 | `params[:a] > nil` compiled as a nil check | Only `==` and `!=` test for nil; an ordering calls `compare`, which raises Ruby's ArgumentError (or NoMethodError for `nil > x`) |
| 9 | An early `return :sym` became a String | Returning a Symbol is refused wherever the value is returned |
| 10 | `:a + "b"` and `"s" + :b` concatenated | Refused: Symbol has no `+`, and String#+ won't take one |
| 11 | `render json:` of a String Value was quoted | `Response::json_value` sends a String as it is, as Rails does, and anything else as JSON |
| 12 | `.to_s` on a Time Value used chrono's format | `Value#to_s`, Ruby's |
| 13 | An array or hash param was nil, so it branched, compared and rendered as nil | Reading one as a value raises. A Value holds only scalars (listed in `gaps.md`) |
| 14 | A Time compared with a Date raised; `midnight == date` was false | A Date compares as its midnight, as Active Support's coercion does |
| 15 | `Date + 100_000_000` and `Time + 9e12` panicked | Checked arithmetic raises "time out of range". `Date ± Float` and `Date - Date` stay refused at run time (listed in `gaps.md`) |
| 16 | `-0.0` printed as `0.0` | Ruby's sign |
| 17 | `Integer % Float` warned (`unused_parens`) | The cast goes into the function call without parentheses |
| — | `"ab" * NaN` gave `""` | Raises (Ruby's FloatDomainError message) |
| — | Instance variables survived a retry | Reset with the helpers (finding 2) |
| — | Fallback wording: "assigned nil and nil", "int or nil or str or nil" | Each class is named once: "str, int or nil" |

The review's pre-0.8 findings in the same area are left for later:

- `params[:a]&.to_i`;
- a Symbol assigned into a String local;
- Bignum JSON params;
- an action named after a Rust keyword;
- `Value#to_s` assuming UTC.
