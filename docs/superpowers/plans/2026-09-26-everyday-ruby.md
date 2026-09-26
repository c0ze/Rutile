# Everyday Ruby (0.7.0)

This records what `feature/everyday-ruby` built, what its adversarial review found, and how each finding was settled.

**Goal:** The Ruby every Rails app writes compiles to what Rails runs: `each`, `select`, `sum`, `find_each`, `map(&:name)`, the aggregates, and `transaction` blocks (roadmap 0.7.0).

**Architecture:**

- **Runtime (RustOnRails):**
  - Relations compute `count`, `sum`, `minimum`, `maximum`, `pluck` and `exists?` in the SQL Rails writes (`relation/calculate.rs`).
  - They walk batches by id for `find_each`.
  - Once loaded, they keep their records, and `size`, `any?`, `first`, `include?` and `pluck` answer from them (`relation/loaded.rs`).
  - Transactions join as Active Record's do. A rollback puts back the records it touched (`transaction.rs`).
  - `sum_integers` and `sum_floats` are `Array#sum`.
- **Compiler (Rutile):**
  - `Iteration` turns blocks into `for` loops over a relation's records or an array.
  - `Lists` answers array methods.
  - `Calculations` maps the relation methods above.
  - `Transactions` compiles a block into a closure the runtime runs, and `raise ActiveRecord::Rollback` into `Error::Rollback`.

**Example:** the store gains `stats`, `low_stock`, `restock_low`, `deactivate_sold_out`, `place`, `reopen` and `summary`. Its 17 integration tests pass on Rails and on the Rust build.

## The review

An agent reviewed the branch adversarially. It ran the same integration tests against Rails 8.1.4 and against the Rust build, and compared the JSON.

| # | Finding | Settled |
|---|---|---|
| 1 | Records saved inside a rolled-back transaction kept their saved state, so a later `save` was skipped | Each open transaction remembers the records it touches; a rollback puts back their id, saved state and destroyed flag, as Rails' `restore_transaction_record_state` does |
| 2 | `raise ActiveRecord::Rollback` in a callback escaped `save` | `save` returns false and `save!` returns without raising, as in Rails. In a joined transaction nothing rolls back |
| 3 | A transaction block ending in `&&`/`||` was always truthy | Using that value is refused |
| 4 | A relation in a local was queried again after `each` had loaded it | Relations keep their loaded records; `size`, `any?`, `empty?`, `first`, `include?`, `pluck` and `find_each` use them, while `count` and the aggregates ask the database, as in Rails |
| 5 | `minimum`/`maximum` of an enum gave the label | They give the integer, as Rails does |
| 6 | `limit(0).first` found a record | nil, without a query |
| 7 | An unsaved owner's has_many matched rows whose key is NULL | It matches nothing (`Relation::none`) |
| 8 | Built, unsaved children don't count in `size` | Listed in `gaps.md`: RustOnRails keeps no association targets |
| 9 | `find_each` keeps every batch in the request's `Ctx` | Documented; handles may point into it, so it can't drop them |
| 10–11 | A dynamic constant path, or `each` without a receiver, crashed Rutile | Refused |
| 12, 18 | A query parameter kept in a local borrowed the request | Query values are owned |
| 13 | `sum_integers`/`sum_floats` weren't reserved names | Added to `Names::FUNCTIONS` |
| 14 | A void method or callback ending in a raise got an unreachable `Ok(())` | `Names.ended` leaves it out |
| 15 | A transaction block that doesn't touch the database left `req` unused | Named `_req` |
| 16 | `to_s` on a nilable local moved it | It copies the local |
| 17 | A local first assigned in two blocks was `let mut` in both | `Names.needless_mut` drops `mut` where nothing assigns the local again in its scope |
| 19 | A `batch_size` past 64 bits | Refused |
| Low | A Symbol mapped into an array became a String | Refused |

## Verification

- `bundle exec rake test`: 313 runs, no failures.
- RustOnRails `cargo test --workspace`: every test passes, with no warnings. New: `calculate_test.rs` and `rollback_test.rs`.
- `rake example:verify`: blog 17/17, tracker 24/24, store 17/17.
