# Benchmarks

Both example apps on Rails and on the Rust crates `rutile build` makes of them, on the same database and rows. Before anything is measured, the task checks that every endpoint gives the same status and byte-for-byte the same body from both servers. Run it with:

```bash
bundle exec rake example:benchmark                  # the blog, one Puma process with YJIT
EXAMPLE=tracker RUNS=3 bundle exec rake example:benchmark
RAILS_WORKERS=4 bundle exec rake example:benchmark  # Puma in cluster mode
RAILS_YJIT=0 bundle exec rake example:benchmark     # Rails on the interpreter
```

## 2026-09-25, blog and tracker, three Rails setups (median of 3 runs)

Requests per second:

| App | Endpoint | Rails, 1 process, interpreter | Rails, 1 process, YJIT | Rails, 4 processes, YJIT | Rust |
|---|---|---:|---:|---:|---:|
| blog | `GET /posts` | 198 | 325 | 1,874 | 14,845 |
| blog | `GET /posts/:id` | 493 | 724 | 5,617 | 39,999 |
| tracker | `GET /projects` | 298 | 495 | 2,660 | 16,237 |
| tracker | `GET /projects/:id` | 203 | 335 | 1,665 | 13,199 |
| tracker | `GET /projects/:id/tasks` | 134 | 229 | 1,136 | 8,270 |
| tracker | `GET /tasks/:id` | 386 | 577 | 3,178 | 25,498 |

The Rust build serves 33 to 55 times the requests of one Puma process running YJIT, the setup Rails 8 gives you. Against a Puma cluster with one process per core, the most Rails gets from this machine, it serves 6 to 8 times as many. Both apps' Rust builds return the same bytes as Rails on every endpoint here.

Latency and memory, Rails with YJIT:

| App | Endpoint | Rails, 1 process: p50 / p99 | Rails, 4 processes: p50 / p99 | Rust: p50 / p99 |
|---|---|---:|---:|---:|
| blog | `GET /posts` | 30.06 / 40.73 ms | 4.51 / 16.46 ms | 0.63 / 1.32 ms |
| blog | `GET /posts/:id` | 13.51 / 19.46 ms | 1.56 / 5.41 ms | 0.23 / 0.55 ms |
| tracker | `GET /projects` | 19.94 / 26.53 ms | 3.42 / 10.53 ms | 0.57 / 1.26 ms |
| tracker | `GET /projects/:id` | 29.04 / 43.74 ms | 5.60 / 16.10 ms | 0.71 / 1.48 ms |
| tracker | `GET /projects/:id/tasks` | 40.92 / 148.93 ms | 8.13 / 19.40 ms | 1.13 / 2.24 ms |
| tracker | `GET /tasks/:id` | 17.06 / 22.93 ms | 2.75 / 9.16 ms | 0.37 / 0.83 ms |
| | memory | 106 to 111 MiB | 369 to 413 MiB | 6 to 7 MiB |

Memory is the proportional set size of the server and its workers, so pages Puma's forked workers share count once. Rails on the interpreter used 86 to 96 MiB.

The tracker's endpoints all authenticate by `X-Api-Token` (a `find_by` on the token) before they do anything:

- `/projects` is Alice's first page of active projects through `has_many :through`, 20 of 42.
- `/projects/:id` renders one project with its 50 tasks (`include: { tasks: { only: ... } }`).
- `/projects/:id/tasks` renders the 50 tasks, each `as_json.merge("overdue" => task.overdue?)`.
- `/tasks/:id` finds a task through `joins(project: :memberships)`.

### Where the time goes

Rust's numbers doubled during this round, with one change in RustOnRails: a connection now keeps its prepared statements, as Rails' adapter does. Before it, every query went through the `postgres` crate's unnamed statement: an extra round trip, and a fresh parse and plan in Postgres. CPU used by each process during a 10-second run, in cores (sampled from `/proc`, good to about a tenth of a core):

| Endpoint | Server | req/s | App server | Postgres |
|---|---|---:|---:|---:|
| `GET /projects` | Rails, 4 processes | 2,618 | 3.2 | 0.4 |
| `GET /projects` | Rust, statements unprepared | 7,085 | 1.4 | 2.2 |
| `GET /projects` | Rust | 15,592 | 2.0 | 1.5 |
| `GET /projects/:id/tasks` | Rails, 4 processes | 1,119 | 3.4 | 0.2 |
| `GET /projects/:id/tasks` | Rust, statements unprepared | 4,408 | 2.1 | 1.6 |
| `GET /projects/:id/tasks` | Rust | 8,087 | 3.1 | 0.7 |
| `GET /tasks/:id` | Rails, 4 processes | 3,142 | 3.1 | 0.4 |
| `GET /tasks/:id` | Rust, statements unprepared | 5,490 | 1.0 | 2.5 |
| `GET /tasks/:id` | Rust | 27,031 | 2.0 | 1.4 |

Per request, the Rust server uses 8 to 13 times less CPU than Rails does: 0.07 to 0.38 ms against 1.0 to 3.0 ms. Every run keeps the machine's 4 cores busy, since the load generator and Postgres share them with the server. Rails' cluster is bound by Ruby, while Rust leaves more than a third of the machine to Postgres on the database-heavy endpoints. On a machine where the database runs elsewhere, the gap would likely widen.

Setup:

- Machine: a 4-vCPU cloud VM (Intel Xeon at 2.1 GHz), 16 GiB, Linux 6.18. It was otherwise idle: the load average was 0.05 before the runs. Postgres, both servers and the load generator all run on it.
- Postgres 16.13 on the repo's local cluster, with each app's test database holding its fixtures plus the benchmark's rows. The blog adds 100 published posts. The tracker adds 40 more projects for Alice and a project with 50 tasks.
- Rails 8.1.4 on Ruby 3.4.9, with `RAILS_ENV=benchmark` (production settings, SSL off, log level `warn`). Puma 8 with 5 threads per process: one process, or 4 in cluster mode. YJIT is on unless `RAILS_YJIT=0`, since Rails 7.2+ enables it.
- Rust: `RustOnRails/examples/blog` and `examples/tracker`, as `rutile build` generates them. Release build, 5 worker threads with one connection each.
- Load: `tools/loadgen` with 10 keep-alive connections. Each endpoint gets a 3-second warm-up, then 3 runs of 10 seconds; the tables give the median run. Rust's figures come from the runs after the statement cache. Rails' single-process figures come from the first matrix, since the Rust change can't affect them. The cluster runs, repeated after the change, came within 3% of the first ones, except the blog's `show` at 13% above (4,960 req/s the first time); the table gives the second runs.

## 2026-09-25, generated code, moderate load (median of 3 runs)

A second run of the `rutile build` output, meant for a quiet machine. It ran on this one instead, with the load average between 5 and 11 across the three runs. Both servers were close to their quiet-run numbers: 28.6 times Rails on the index, 20.2 times on `show`. Rails swung more between runs (the third run's `show` fell to 779 req/s); Rust's `show` stayed at 23,000 in all three.

| Endpoint | Server | req/s | p50 | p99 | RSS |
|---|---|---:|---:|---:|---:|
| `GET /posts` | Rails | 308 | 29.12 ms | 64.22 ms | 102 MiB |
| `GET /posts` | Rust | 8,824 | 1.10 ms | 1.77 ms | 8 MiB |
| `GET /posts/:id` | Rails | 1,150 | 8.53 ms | 11.51 ms | 103 MiB |
| `GET /posts/:id` | Rust | 23,266 | 0.41 ms | 0.90 ms | 9 MiB |

## 2026-09-25, generated code, machine under load

The Rust side here is `rutile build` output. Other work on the machine had the load average at 19.7 when the run started and 34.4 when it ended, so both servers are slower than in the quiet run below. They ran back to back under the same contention, so the ratios are the useful part: 27 times Rails on the index, 16.5 times on `show`.

| Endpoint | Server | req/s | p50 | p99 | RSS |
|---|---|---:|---:|---:|---:|
| `GET /posts` | Rails | 176 | 54.94 ms | 98.35 ms | 96 MiB |
| `GET /posts` | Rust | 4,770 | 1.91 ms | 4.40 ms | 8 MiB |
| `GET /posts/:id` | Rails | 554 | 16.54 ms | 33.57 ms | 97 MiB |
| `GET /posts/:id` | Rust | 9,137 | 0.98 ms | 3.01 ms | 9 MiB |

## 2026-09-25, hand port, quiet machine

| Endpoint | Server | req/s | p50 | p99 | RSS |
|---|---|---:|---:|---:|---:|
| `GET /posts` | Rails | 363 | 27.23 ms | 31.26 ms | 101 MiB |
| `GET /posts` | Rust | 9,726 | 1.00 ms | 1.38 ms | 8 MiB |
| `GET /posts/:id` | Rails | 1,167 | 8.40 ms | 10.44 ms | 102 MiB |
| `GET /posts/:id` | Rust | 24,924 | 0.39 ms | 0.56 ms | 9 MiB |

That is 27 times the throughput on the index and 21 times on `show`, in under a tenth of the memory.

`/posts` renders the 20 most recent visible posts with their authors (`includes(:user)`, two queries). `/posts/:id` renders one post.

Setup:

- Machine: an 8-core desktop (16 threads), 64 GiB, Linux. Postgres, both servers and the load generator all run on it.
- Postgres 16.15, the repo's local cluster (`rake pg:start`), database `blog_test` holding the test fixtures plus 100 published posts.
- Rails 8.1.4 on Ruby 3.4.9, `RAILS_ENV=benchmark`: production settings with SSL off and the log level at `warn`. One Puma process, 5 threads.
- Rust: `RustOnRails/examples/blog` (the hand port for the quiet run, `rutile build` output for the one above), release build, 5 worker threads with one connection each.
- Load: RustOnRails' `tools/loadgen`, 10 keep-alive connections. Each run gets a 3-second warm-up, then 10 seconds measured. RSS is read from `ps` right after.

## Caveats

- The three earlier sections ran on a Ruby built without YJIT, one Puma process, and a different machine (the 8-core desktop). The first section adds both on this machine: YJIT raises Rails' throughput 1.5 to 1.7 times, and cluster mode on 4 cores another 5 to 8 times.
- One Puma process is bound by the GVL, and its 5 threads mostly help while a request waits on Postgres. Cluster mode forks one process per core, which raises Rails' memory with its throughput.
- Small tables on a local Postgres, with the load generator competing for the same CPU. Numbers on a real network and a real dataset will differ for both servers.

The first run had the Rust index at 245 req/s, slower than Rails, with a flat 41 ms p50. The server then ran on tiny_http, which writes a response's headers and body separately and leaves Nagle's algorithm on, so the body sat in the kernel until the client's delayed ACK for the headers arrived. RustOnRails now has its own HTTP/1.1 layer, which writes each response in one piece with `TCP_NODELAY` set.
