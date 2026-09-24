# Benchmarks

The blog example on Rails and on its Rust port, same database, same rows. Run it with:

```bash
bundle exec rake example:benchmark
```

## 2026-09-25

| Endpoint | Server | req/s | p50 | p99 | RSS |
|---|---|---:|---:|---:|---:|
| `GET /posts` | Rails | 363 | 27.23 ms | 31.26 ms | 101 MiB |
| `GET /posts` | Rust | 9,726 | 1.00 ms | 1.38 ms | 8 MiB |
| `GET /posts/:id` | Rails | 1,167 | 8.40 ms | 10.44 ms | 102 MiB |
| `GET /posts/:id` | Rust | 24,924 | 0.39 ms | 0.56 ms | 9 MiB |

That is 27 times the throughput on the index and 21 times on `show`, in under a tenth of the memory.

`/posts` renders the 20 most recent visible posts with their authors (`includes(:user)`, two queries). `/posts/:id` renders one post.

Setup:

- Machine: Ryzen 7 5700X3D (8 cores, 16 threads), 64 GiB, CachyOS on Linux 7.2.6. Postgres, both servers and the load generator all run on it.
- Postgres 16.15, the repo's local cluster (`rake pg:start`), database `blog_test` holding the test fixtures plus 100 published posts.
- Rails 8.1.4 on Ruby 3.4.9, `RAILS_ENV=benchmark`: production settings with SSL off and the log level at `warn`. One Puma process, 5 threads.
- Rust: the hand port in `RustOnRails/examples/blog`, release build, 5 worker threads with one connection each.
- Load: RustOnRails' `tools/loadgen`, 10 keep-alive connections. Each run gets a 3-second warm-up, then 10 seconds measured. RSS is read from `ps` right after.

## Caveats

- The Rust side is the hand port from plan 4, not `rutile build` output. The port is written the way codegen will write it, but generated code hasn't been measured yet.
- This Ruby was built without YJIT, so Rails ran on the interpreter. YJIT would narrow the gap somewhat; by how much, we haven't measured.
- One Puma process is bound by the GVL, and its 5 threads mostly help while a request waits on Postgres. Puma in cluster mode, one process per core, would raise Rails' throughput and its memory together. Not measured.
- Small tables on a local Postgres, with the load generator competing for the same CPU. Numbers on a real network and a real dataset will differ for both servers.

The first run had the Rust index at 245 req/s, slower than Rails, with a flat 41 ms p50. The server then ran on tiny_http, which writes a response's headers and body separately and leaves Nagle's algorithm on, so the body sat in the kernel until the client's delayed ACK for the headers arrived. RustOnRails now has its own HTTP/1.1 layer, which writes each response in one piece with `TCP_NODELAY` set.
