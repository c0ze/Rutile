# Benchmarks

`rake example:benchmark` runs an example app on Rails and on the Rust crate `rutile build` made of it, against the same database and rows. Before measuring, it checks that every endpoint gives the same status and byte-for-byte the same body from both servers; it stops if any differs. The full results, setups and history are in [benchmarks.md](../benchmarks.md).

```bash
bundle exec rake example:benchmark                                # the blog, one Puma process with YJIT
EXAMPLE=tracker RUNS=3 bundle exec rake example:benchmark         # median of 3 runs
EXAMPLE=store RAILS_WORKERS=10 bundle exec rake example:benchmark # Puma in cluster mode
RAILS_YJIT=0 bundle exec rake example:benchmark                   # Rails on the interpreter
```

## Latest: 2026-09-28, Apple M4

Requests per second, median of 3 runs of 10 seconds with 10 keep-alive connections. Rails is 8.1.4 on Ruby 3.4.9 with YJIT, under Puma with 5 threads per process; Rust is the generated crate's release build with 5 worker threads.

| App | Endpoint | Rails, 1 process | Rust | ratio | Rails, 10 processes | Rust | ratio |
|---|---|---:|---:|---:|---:|---:|---:|
| blog | `GET /posts` | 656 | 19,449 | 29.6 | 2,629 | 12,316 | 4.7 |
| blog | `GET /posts/:id` | 2,622 | 52,494 | 20.0 | 8,951 | 48,016 | 5.4 |
| tracker | `GET /projects` | 820 | 18,959 | 23.1 | 2,380 | 20,985 | 8.8 |
| tracker | `GET /projects/:id` | 599 | 13,717 | 22.9 | 1,825 | 14,128 | 7.7 |
| tracker | `GET /projects/:id/tasks` | 364 | 10,872 | 29.9 | 415 | 7,594 | 18.3 |
| tracker | `GET /tasks/:id` | 1,599 | 30,117 | 18.8 | 3,815 | 22,854 | 6.0 |
| store | `GET /products` | 923 | 25,073 | 27.2 | 3,184 | 24,208 | 7.6 |
| store | `GET /products/:id` | 2,377 | 52,984 | 22.3 | 10,956 | 52,622 | 4.8 |
| store | `GET /products/stats` | 501 | 6,734 | 13.4 | 2,416 | 7,010 | 2.9 |
| store | `GET /shop` (ERB page) | 702 | 22,404 | 31.9 | 4,146 | 22,861 | 5.5 |
| store | `GET /shop/:id` (ERB page) | 889 | 19,324 | 21.7 | 3,922 | 20,462 | 5.2 |
| store | `GET /cart` (Rails' session cookie) | 2,954 | 85,002 | 28.8 | 12,198 | 95,092 | 7.8 |

In short:

- Against one Puma process, the setup Rails 8 gives you, the Rust build serves 19 to 32 times the requests on every endpoint but `/products/stats`.
- Against a Puma cluster with a process per core, it serves 5 to 9 times as many on most endpoints (4.7 on the blog's index), and 18 times on the tracker's task list, where Rails spends its time in Ruby: 50 records, each merged with a computed field.
- `/products/stats` runs twelve queries a request, most of them aggregates, so Postgres does most of the work for either server: 13 times one process, 2.9 times the cluster.
- `/cart` decrypts a session cookie Rails wrote, on every request, on both servers.
- p50 latency on Rust is 0.11 to 1.4 ms; on one Puma process, 3.1 to 27 ms.
- Memory: about 10 MiB for the Rust server, 102 to 117 MiB for one Puma process.

## Reading the numbers

- Postgres, both servers and the load generator share one machine, so every figure includes contention for its cores. The M4 run was on a desktop in use (load average 3.8 to 15). Each ratio compares two servers measured under the same conditions in the same run.
- The tables are small and local. On a real network and dataset both servers will differ; the gap may narrow where the database dominates, as `/products/stats` shows.
- An earlier run on a 4-vCPU Linux VM measured 33 to 55 times one Puma process and 6 to 8 times a 4-process cluster on the blog and the tracker. Rails gained more from the faster machine than Rust did, which narrows the single-process ratio. See [benchmarks.md](../benchmarks.md) for that run and the history of what changed the Rust numbers, such as the prepared statement cache.

The example apps are described in [Examples](Examples.md), and how the runtime serves a request in [Runtime](Runtime.md).
