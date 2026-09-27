# Runtime

[RustOnRails](https://github.com/c0ze/RustOnRails) is the crate a generated app links against. It implements the parts of the Rails API that generated code calls (`Post::find`, `params.require(...)`, `render json:`), with Rails' behavior where an app can observe it: callback order, validation messages, dirty tracking, relation laziness, status codes. Its names follow Rails, so the generated Rust reads like the Ruby it came from. Writing RustOnRails apps by hand is possible but not a goal.

This page describes how it runs a request. The design notes are in RustOnRails' [docs/design.md](https://github.com/c0ze/RustOnRails/blob/main/docs/design.md), and its known defects in [docs/open-items.md](https://github.com/c0ze/RustOnRails/blob/main/docs/open-items.md).

## Synchronous code

Generated code is synchronous, like the Ruby it comes from. Rails serves concurrent requests with threads under Puma, and so does RustOnRails: each request runs on a worker thread with its own `Ctx`, and the database driver is the blocking `postgres` crate. An async runtime would put `async` and `.await` on nearly every generated method, since nearly all of them may touch the database, and turn callback tables into boxed futures.

## Ctx and the record table

A `Ctx` is one unit of work: a database connection, plus every record that unit loaded or built. The server makes a fresh `Ctx` for each request, and the worker one for each job. Records live in the `Ctx`'s record table; variables hold a `Handle<Post>`, a `Copy` index into it. Indexing the `Ctx` with a handle reaches the record:

```rust
let a = Post::find(ctx, 1)?; // Handle<Post>
let b = a;
ctx[b].title = Some("x".into());
assert_eq!(ctx[a].title.as_deref(), Some("x")); // same record, as in Ruby
```

This is how Ruby's shared objects survive without a garbage collector:

- Copying a handle doesn't copy the record, so two variables naming one object see each other's changes, as in Ruby.
- There's no identity map. Like Rails, each load makes a new record: two `Post.find(1)` calls give two independent records, and `==` between records compares ids, as Active Record does.
- Generated code never holds `&mut Post` across calls, so the borrow checker never gets in the way and there's no `RefCell` to panic.
- Everything the request allocated goes when its `Ctx` is dropped, in one step, when the response goes out.
- A handle means something only in the `Ctx` that made it. A relation loaded in one `Ctx` and asked in another queries again rather than reading the first one's records.

The cost is that memory a request uses comes back only when the request ends. `find_each` queries 1,000 rows at a time, but the records it loads stay in the `Ctx` until the request ends, since a handle into them may live on.

Generated code follows one rule from this: an argument that reads the `Ctx` is bound to a local before a call that borrows the `Ctx` mutably. `Post::find(ctx, ctx[comment].post_id)` doesn't compile; `let id = ctx[comment].post_id; Post::find(ctx, id)` does.

State that outlives a request is rare in a well-behaved Rails app. Constants are built once. Class variables and mutable globals are refused by `rutile check` ([The Ruby Subset](The-Ruby-Subset.md)).

## Models

A model is a plain struct with one `Option<T>` field per column, since any Ruby attribute can be nil until the database says otherwise. The `model!` macro declares it with its table and the columns' database defaults. The store's `Product`:

```rust
model! {
pub struct Product in "products" {
id: i64,
name: String,
price_cents: i64,
stock: i64 = 0,
active: bool = true,
created_at: Time,
updated_at: Time,
}
}
```

What the class body declares (`belongs_to`, `enum`, `validates`, callbacks) becomes a static `Behavior`, built in the order Rails runs it, since order is behavior. The generated server builds every model's `Behavior` when it starts, so a problem such as a validator's regexp Rust can't parse stops it at boot, naming the model's file, rather than on a request.

Class-level methods (`find`, `find_by`, `create!` as `create_bang`) are on the `Model` trait. Instance-level ones (`save`, `valid?` as `is_valid`, `update`, `destroy`, `reload`) are methods on `Ctx` that take a handle. See [Models](Models.md).

## Relations

A `Relation<M>` is a lazy query, like `ActiveRecord::Relation`: nothing runs until `load`, `first`, `count`, `exists` or a finder. Scopes are extension traits on it, so `Post.visible.recent` is `Post::all().visible().recent()`.

Once a relation has loaded, `size`, `any?`, `empty?`, `first` and `pluck` answer from its records, as Rails' do; `count`, `exists?` and the aggregates still ask the database. A relation is a value: two locals naming one relation (`b = a`) are two copies, so loading one doesn't load the other, where in Ruby they are one object. See [Queries](Queries.md).

## Transactions

`transaction do ... end` compiles to a closure that `Ctx::transaction_block` runs. It gives the block's value, or nil after `raise ActiveRecord::Rollback`; any other error rolls back and goes on up. `save` and `destroy` run in a transaction of their own, as in Rails.

- **Joining.** A transaction opened inside another joins it, as in Active Record: only the outermost one commits or rolls back. `ActiveRecord::Rollback` raised in a joined block is swallowed there and rolls nothing back; the outer block commits it all. A `save` that fails inside a transaction block leaves the block's other writes in place.
- **Savepoints.** A transaction opened inside one that can't be joined gets a savepoint (`SAVEPOINT active_record_1`). In practice that's the test's own transaction, which, like Rails' fixture transaction, isn't joinable, so a transaction a test runs behaves as it would in Rails. `transaction(requires_new: true)` and other options are refused.
- **Restore on rollback.** Each transaction remembers the records it saves or destroys, and their state when it first touched them. If it rolls back, each gets back its id, its saved state and its destroyed flag, as Rails' `restore_transaction_record_state` does: a record created in the block is new again, so a later `save` inserts it, and a record destroyed in the block isn't destroyed. Attributes keep their new values, which count as changes again. A savepoint that commits hands its records to the transaction around it, so they roll back with it.
- **Failed commits.** A `COMMIT` can fail where no statement before it did, on a deferred constraint. The database has rolled back, so the records go back too, and the error goes on up.

## Prepared statements

A `Connection` keeps the statements prepared on it across requests, up to Rails' `statement_limit` of 1,000, dropping the oldest past it. Postgres parses and plans each query once per connection, as with Rails' statement cache. Relations with a SQL fragment run unprepared, as in Rails, since their binds are written into the SQL and each value would be a statement of its own.

When a migration changes a table under a prepared statement, Postgres fails it once with "cached plan must not change result type". The connection then drops its statements, and the next query prepares again instead of failing until the worker restarts.

## Lost connections

A connection is replaced rather than reused once the database has closed it (a restart, a failover, an idle kill): after a FATAL or PANIC error from Postgres, a socket error, or the driver seeing the socket close. The worker opens a new connection for its next request, and its prepared statements start over.

The driver only notices a closed socket when it next reads from it, so after Postgres restarts, each worker's first request that touches the database fails with a 500, and the worker reconnects for its next one. A request that doesn't touch the database, such as the health check, succeeds and leaves the dead connection in place. Rails 7.1 and later reconnect and retry an idempotent read there. This is listed in RustOnRails' [open items](https://github.com/c0ze/RustOnRails/blob/main/docs/open-items.md).

A handler that panics costs a 500. It costs the worker's connection only when it left a transaction open, so a request that overflows an integer doesn't make the next one reconnect.

## The HTTP server

The server is RustOnRails' own HTTP/1.1 on `std::net` ([src/http/server.rs](https://github.com/c0ze/RustOnRails/blob/main/src/http/server.rs), [wire.rs](https://github.com/c0ze/RustOnRails/blob/main/src/http/wire.rs)).

- **Workers.** A fixed pool of `WORKERS` threads, Puma's threads, each owning one Postgres connection. They take fully read requests from one queue.
- **Connections.** Each connection gets a thread that reads requests off it in full, head and body, before handing them to a worker. A slow or stalled client holds its own thread, never a worker or a database connection.
- **Keep-alive and pipelining.** HTTP/1.1 connections stay open unless the client says `Connection: close`; HTTP/1.0 ones close unless it says `keep-alive`. Pipelined requests are answered in order.
- **Bodies.** By `Content-Length` or chunked (trailers are read and ignored), never both. `Expect: 100-continue` gets its `100 Continue` once the declared size is known to be acceptable. JSON media types are parsed as JSON, form bodies become params, and anything else is left unparsed.
- **HEAD** runs the matching GET route and sends its headers without the body.
- **Responses** go out in one write with `TCP_NODELAY` set, so the last segment isn't held for the client's delayed ACK.

### Limits

`Limits` ([src/http/limits.rs](https://github.com/c0ze/RustOnRails/blob/main/src/http/limits.rs)) bounds what one client can hold of the server. Each limit has an environment variable, listed on [Configuration](Configuration.md).

- **Connections.** At most `MAX_CONNECTIONS` are served at once. A connection past it gets a 503 and is closed at once, so slow clients can't take every thread, and at most that many requests wait for the workers.
- **Heads.** A request line and headers may take 16 KiB, a 431 past it, and must arrive within `HEADER_TIMEOUT` of the first byte, however slowly they trickle in, a 408 past it.
- **Bodies.** A body may be `MAX_BODY_BYTES`; a larger declared length is a 413 before any of it is read. It must arrive within `BODY_TIMEOUT`, plus a second for each `MIN_RATE` bytes that arrive, so a large body can take as long as it needs at that rate and a trickle can't; a 408 past it.
- **Responses.** Writing one gets `WRITE_TIMEOUT`, plus a second for each `MIN_RATE` bytes written, or the connection is closed.
- **Idle connections** wait `IDLE_TIMEOUT` for their next request.

After refusing a request, the server reads and discards what the client is still sending for up to a second (and up to 1 MiB) before closing, so the kernel doesn't reset the connection and destroy the response before the client reads it.

What these refusals look like to a client is on [Middleware and Errors](Middleware-and-Errors.md#request-limits). Two gaps are listed in the runtime's open items: bodies in flight are bounded per connection only (at the defaults, `MAX_CONNECTIONS` × `MAX_BODY_BYTES` is 5 GiB), and the body deadline's credit is earned up front, so a client that sends all but the last byte of a large body at once can then stall for as long as that body earned.

### Starting and stopping

`server::start` binds, starts the workers and returns; the generated `main.rs` then waits on it. `Running::stop` stops accepting and lets each worker finish its current request, but the generated binary doesn't call it and installs no signal handler, so stopping the process ends requests in flight.

The server writes to standard error only: `APP listening on ADDRESS` at start, and a line for each request that failed.

## Postgres over TLS

`DATABASE_URL` is a Postgres URL or a libpq `key=value` string. Connections use TLS as libpq reads the URL's `sslmode` and `sslrootcert`, except that `allow` behaves as `prefer`, through `native-tls` (the platform's TLS library: OpenSSL on Linux):

| `sslmode` | Behavior |
|---|---|
| `disable` | No TLS |
| `allow`, `prefer` (the default) | TLS when the server offers it, unverified |
| `require` | TLS, unverified unless there's a root certificate file, in which case the chain is verified |
| `verify-ca` | TLS, with a certificate a trusted CA signed |
| `verify-full` | That, for this host name too |

The root certificates are `sslrootcert`, or libpq's default `~/.postgresql/root.crt` when it exists. A root file's CAs are the only ones trusted. `sslrootcert=system` trusts the operating system's CAs, and only with `verify-full`, which it makes the default mode, since any public CA can sign a certificate for some name. `verify-ca` and `verify-full` with no root certificate fail rather than trust anything.

In a URL, write `@`, `/` and `?` in the user name, password and query as `%40`, `%2F` and `%3F`. A URL with an `@` after its host is refused, since the driver would read part of the path or query as the user name and drop the query's `sslmode`. In a `key=value` string, values are read as libpq reads them, quotes and backslash escapes included, so `application_name='x sslmode=disable'` is one setting.

## Jobs, sessions and views

The rest of the runtime has pages of its own: [Jobs](Jobs.md) for the Sidekiq client and worker, [Sessions and Cookies](Sessions-and-Cookies.md) for the cookie store, [Views](Views.md) for templates, and [Middleware and Errors](Middleware-and-Errors.md) for what the router does around every request.
