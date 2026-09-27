# Jobs

Active Job classes on the Sidekiq adapter compile to Rust. `perform_later` in the binary pushes the payload Sidekiq 8's Active Job adapter pushes, key for key, onto the same Redis queue. The binary also carries a worker, `APP work`, that takes jobs off those queues and runs them. A job Rails enqueues can run on the Rust worker, and a job the binary enqueues can run on Sidekiq's Ruby worker.

Since 0.10.0. The Rust side is [src/jobs/](https://github.com/c0ze/RustOnRails/blob/main/src/jobs/mod.rs); the compiler side is [lib/rutile/build/job_file.rb](../../lib/rutile/build/job_file.rb) and [job_calls.rb](../../lib/rutile/build/job_calls.rb).

## A job

The store's [restock_job.rb](../../examples/store/app/jobs/restock_job.rb):

```ruby
class RestockJob < ApplicationJob
  queue_as :default

  #: (Product, Integer) -> void
  def perform(product, amount)
    product.restock!(amount)
  end
end
```

becomes `src/jobs/restock_job.rs`:

```rust
// app/jobs/restock_job.rb:3
pub const RESTOCK_JOB: Job = Job {
    class: "RestockJob",
    queue: "default",
};

// app/jobs/restock_job.rb:7
pub fn run(ctx: &mut Ctx, product: Handle<Product>, amount: i64) -> Result<()> {
    Product::restock_bang(ctx, product, amount)?;
    Ok(())
}

/// What a worker runs, with the arguments Active Job serialized.
pub fn perform(ctx: &mut Ctx, arguments: &[Json]) -> Result<()> {
    jobs::arity(arguments, 2)?;
    let product = jobs::record_at::<Product>(ctx, arguments, 0)?;
    let amount = jobs::scalar_at::<i64>(arguments, 1)?;
    run(ctx, product, amount)
}
```

`run` is `perform` as written. `perform` is what the worker calls: it checks the argument count, as Ruby does before `perform` runs, and turns Active Job's serialized arguments back into the signature's types.

A `perform` with parameters needs an rbs-inline signature, and its parameters must be required positional ones. See [Types and Signatures](Types-and-Signatures.md).

`src/jobs/mod.rs` lists the app's jobs for the worker, and records what Active Job writes with every job:

```rust
pub const APP: JobApp = JobApp {
    name: "store",
    locale: "en",
    timezone: "UTC",
};
```

`name` is the app's `GlobalID.app`.

## Enqueuing

```ruby
def restock_later
  RestockJob.perform_later(@product, amount(params.fetch(:amount, 1).to_i))
  render json: { queued: true }, status: :accepted
end
```

```rust
let product = self.product;
let amount = req.params.fetch("amount", 1)?.to_i()?;
let amount_2 = self.amount(req, amount)?;
crate::jobs::restock_job::RESTOCK_JOB.perform_later(
    &crate::jobs::APP,
    vec![
        rustonrails::jobs::record_argument::<Product>(
            &req.ctx,
            &crate::jobs::APP,
            product,
        )?,
        {
            let argument: i64 = amount_2;
            Json::from(argument)
        },
    ],
)?;
Ok(Response::json(202, json!({ "queued": true })))
```

The arguments are checked against the job's signature, as for any method call: `RestockJob.perform_later(product, "2")` is refused (`passing str to RestockJob.perform_later's amount (int)`), and so is a call with the wrong number of arguments.

The payload goes on `queue:<name>` with `LPUSH`, and the queue name into the `queues` set, as Sidekiq's client does:

```json
{"retry": true, "queue": "default", "wrapped": "RestockJob",
 "args": [{"job_class": "RestockJob", "job_id": "...", "provider_job_id": null, "queue_name": "default",
           "priority": null, "arguments": [{"_aj_globalid": "gid://store/Product/7"}, 4],
           "executions": 0, "exception_executions": {}, "locale": "en", "timezone": "UTC",
           "enqueued_at": "...", "scheduled_at": null}],
 "class": "Sidekiq::ActiveJob::Wrapper", "jid": "...", "created_at": 1790000000000, "enqueued_at": 1790000000000}
```

`perform_now` runs the job's `run` in the same request: `RestockJob.perform_now(product, 2)` is `crate::jobs::restock_job::run(&mut req.ctx, product, 2)?`.

The server connects to Redis on the first `perform_later` in each worker thread. A connection that breaks is dropped and the command tried once more on a new one, as Sidekiq's client reconnects. A Redis that answers `READONLY` (a primary that became a replica) counts as broken. A Redis that can't be reached fails the request with a 500.

## Arguments

| Parameter type | Serialized as | Read back by the worker |
|---|---|---|
| a model (`Product`) | its GlobalID, `{"_aj_globalid": "gid://store/Product/7"}` | `find` by id; a missing row raises `ActiveJob::DeserializationError` |
| `Integer`, `Float`, `String`, `bool` | JSON | the JSON value, which must have that type |
| `T?` of `Integer`, `Float`, `String` or `bool` | the value or `null` | nil allowed |

As in Rails:

- A record that was never saved raises `ActiveJob::SerializationError` at `perform_later`.
- A nil record is enqueued as `null` by `perform_later`; the job fails when it runs. `perform_now` refuses a value that may be nil where the signature says `Product`.
- A Float that is NaN or Infinity raises `JSON::GeneratorError`, since Active Job's JSON has no such numbers.
- The worker finds a record by id whichever app its GlobalID names, as GlobalID's default locator does.

Refused: a nilable model (`Product?`), and parameters of any other type. Time, Date, Symbol, Hash and Array go through Active Job's own serializers, which the runtime doesn't implement (`RestockJob's at, time, as a job argument`).

## The worker

An app with jobs gets a second mode in its binary:

```
$ DATABASE_URL=postgres://... REDIS_URL=redis://localhost:6379/0 store work
```

It takes jobs from the queues of the app's compiled jobs (`default` for the store), which are fixed at build time. `store work --once` takes one job, waiting up to 5 seconds for it, runs it and exits; it exits with an error when the job fails or none came. [Configuration](Configuration.md) lists what the worker reads.

Each job runs in a fresh `Ctx`, on a database connection the worker keeps between jobs and replaces when the database closed it. The worker runs one job at a time; run more processes for more at once.

About every 5 seconds it moves the jobs that are due from Sidekiq's `retry` and `schedule` sorted sets back onto their queues, as Sidekiq's scheduler does. The move is one Lua script (`ZREM`, then `LPUSH` only if the `ZREM` removed it), so two workers never enqueue a job twice and a lost connection can't lose it. So jobs Rails scheduled with `set(wait:)` or `set(wait_until:)` run on the Rust worker when they're due.

## Failures, retries and the dead set

A job that raises, or panics, fails the way Sidekiq fails it:

- The payload gets `error_message`, `error_class` (the Ruby class the error stands for, such as `ActiveRecord::RecordNotFound`), `failed_at` or `retried_at`, and `retry_count`.
- It goes on the `retry` set, due after Sidekiq's backoff: `count⁴ + 15 + rand(10) × (count + 1)` seconds, so the first retry comes after 15 to 24 seconds.
- After 25 retries it goes on the `dead` set, which is trimmed to 10,000 jobs and six months, as Sidekiq trims it.
- The payload's own options are followed: `retry: false` drops the job, a number is its retry limit, `dead: false` keeps it off the dead set, and `retry_queue` is where its retries go.

A panic counts as a `RuntimeError`, or a `RangeError` when it was an integer overflow (a Bignum in Ruby). The worker survives it, and survives a lost database or Redis: it waits a second and tries again. Sidekiq's web UI shows these jobs like any others.

## Sharing queues with Ruby workers

Both sides speak Sidekiq's format, so they can share Redis during a migration. The store's [jobs_test.rb](../../examples/store/test/integration/jobs_test.rb) checks both directions: a job the binary enqueues is run by `Sidekiq::ActiveJob::Wrapper` in Ruby, and a job `RestockJob.perform_later` enqueued in Rails is run by `store work --once`.

The Rust worker runs every Active Job payload on the queues it's given. Give it queues whose jobs the Rust build has:

- An Active Job class the build doesn't have fails with `ActiveJob::UnknownJobClassError` and goes on the retry set.
- A plain `Sidekiq::Job` payload (not wrapped by Active Job) fails with `NameError` and goes on the retry set.

Either way a Ruby worker on the same queue may take the job after the backoff.

## What's refused

- **Other queue adapters.** Jobs compile only on `:sidekiq`; a `perform_later` on another adapter is refused (`RestockJob on the async queue adapter; jobs run on Sidekiq's`).
- **Class-body declarations other than `queue_as`**, in the job and in `ApplicationJob`: `retry_on`, `discard_on`, `sidekiq_options`, `before_perform` and the other callbacks. When a job inherits its `perform`, its own file is checked as well.
- **`enqueue_after_transaction_commit`**: the binary enqueues at once, so a job that waits for the commit is refused.
- **Namespaced job classes** (`Admin::RestockJob`).
- **`queue_name_prefix`**, which Rails usually sets per environment.
- **A queue a block chooses** (`queue_as { ... }`).
- **`set(wait:)`, `set(queue:)` and other `set` calls** in the binary. The worker still runs jobs Rails scheduled.
- **A job without a `perform`**, a `perform` with parameters and no signature, and optional or keyword parameters.
- **Arguments** other than records, Integers, Floats, Strings, booleans and nil.
- **Plain `Sidekiq::Job` classes**: only Active Job classes are compiled.
- **`rediss://` URLs.** Only `redis://` is spoken; anything else stops the server and the worker at startup.

The full list is on [Limitations](Limitations.md).
