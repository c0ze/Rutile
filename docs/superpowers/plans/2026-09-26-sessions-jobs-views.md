# Sessions, jobs and views (0.10.0)

This records what `feature/sessions-jobs-views` built, what its adversarial review found, and how each finding was settled.

**Goal:** A Rails sidecar and the Rust binary read each other's sessions, Ruby and Rust workers share a Sidekiq queue, and an ERB page renders the bytes Rails does (roadmap 0.10.0).

## Sessions

- **Runtime (RustOnRails):**
  - `CookieKey` derives Rails 8.1's cookie key: PBKDF2-SHA256 of `secret_key_base` with the salt "authenticated encrypted cookie", 1000 iterations, 32 bytes.
  - It seals AES-256-GCM messages in Rails' envelope: `{"_rails":{"message":…,"exp":null,"pur":"cookie.NAME"}}`, as `data--iv--tag` in Base64.
  - `Session` loads when it's written, or when it's read while the request's cookie holds one. One that loaded goes back re-encrypted (`path=/; httponly; samesite=lax`); one that never loaded sends nothing.
  - `Cookies` parses and sets plain cookies with Rack's escaping.
  - An error page carries no cookies, because Rails' middleware never sees them.
- **Compiler (Rutile):**
  - `Sessions` compiles `session[:key]`, `session[:key] = value`, `session.delete` and `reset_session`, and `cookies[:name]` reads and writes.
  - Introspection reads the store and the cookie name from the middleware stack.
  - The crate's `main` reads `SECRET_KEY_BASE`.
- **Example:** the store's cart lives in the session. One test takes a cookie Rails wrote to the binary and back.

## Jobs

- **Runtime:**
  - `jobs::Job::perform_later` pushes Sidekiq 8's Active Job payload, key for key, as captured from Rails. Records are GlobalIDs, and nil stays nil.
  - `jobs::work` BRPOPs the app's queues and runs each job in a fresh `Ctx`. A failure goes on Sidekiq's retry set with Sidekiq's backoff, and on its dead set after 25 retries. Retries that come due go back on their queues.
  - Active Job's serialization errors and the unknown-class error come with Rails' messages.
- **Compiler:**
  - Introspection records each Active Job class, its queue and whether it enqueues after commit.
  - `JobFile` makes `src/jobs/<job>.rs`: `run` is `perform` typed by its rbs-inline signature, and `perform` takes the serialized arguments.
  - `JobCalls` compiles `perform_later` and `perform_now`.
  - The crate's binary gains `work [--once]`.
- **Example:** `RestockJob`. One test has Sidekiq's Ruby processor run a job the binary enqueued. The other has the binary's worker run a job Rails enqueued.

## Views

- **Runtime:**
  - `View` is the output buffer: template text as it is, `<%= %>` values escaped with `ERB::Util.html_escape`'s five characters, and `content_for` with `.presence`.
  - The layout's `yield` gives the template's output.
  - `link_to` writes the given attributes, then `href`, each escaped.
  - `path_segment` escapes as Journey's `escape_segment` does.
- **Compiler:**
  - Introspection compiles each template with Rails' own ERB handler and records the Ruby it makes (`@output_buffer.safe_append=…`, `append=( … )`). The build translates that Ruby, so Rails' trimming (`<% %>` lines, `-%>`, comments) is Rails' own, not a reimplementation.
  - A template becomes a method on its controller, reading the controller's instance variables as Rails copies them into the view.
  - An action that renders nothing renders its template in the layout. The layout is the declared one, or the first `layouts/<controller path>` up the app's controllers.
  - Rails' forgery-protection filters are left out while every route to the controller is a GET.
  - Each named route gets a `_path` function in `routes.rs`.
- **Example:** the storefront, `StorefrontController < ActionController::Base`, has a layout and two templates. Its five tests assert Rails' exact bytes, including a name that needs escaping, `content_for(:title) || …`, `-%>`, a comment and a non-ASCII footer. The binary passes all five.

33 store integration tests pass on Rails and on the Rust build, and the blog's 17 and the tracker's 24 still do.

## The review

An agent reviewed the branch adversarially. It worked on copies of both repos, with its own Redis and databases. It compared pages and headers from a production-mode Rails server with the Rust release binary, crafted Sidekiq payloads, and ran `cargo check` on generated crates.

| # | Finding | Settled |
|---|---|---|
| H1 | A panic in a job (an Integer overflow) killed `work`, and the job, already off its queue, was lost | The worker runs each job under `catch_unwind`. A panic fails the job onto the retry set (as a RangeError for an overflow), and its connection is dropped in case a transaction was open |
| H2 | The worker never reopened a database connection the database closed | A closed connection is opened again before the next job, as the server does |
| H3 | `ApplicationJob`'s `retry_on`, `discard_on`, `sidekiq_options` and callbacks were silently ignored | Introspection records each job's app-defined ancestors, and their class bodies are checked like the job's own: anything but `queue_as` is refused |
| H4 | The session store's `secure:`, `same_site:`, `domain:` and `expire_after:` options, and `force_ssl`, were ignored | `path:`, `secure:`, `httponly:` and `same_site:` are honoured, and so is `cookies_same_site_protection` for plain cookies. `force_ssl` behind `assume_ssl` adds HSTS and marks cookies secure, as Rails' SSL middleware does. `domain:`, `expire_after:`, per-request SameSite, force_ssl without assume_ssl, and non-default `ssl_options` are refused |
| M1 | A bare `CookieStore` middleware got the app's cookie name, not Rack's `_session_id` | The name comes from the middleware's own options, else `_session_id` |
| M2 | `cargo check` failed on a Base controller with only Rails' filters (unused `req`), on `<%= a == b %>` and `<%= !x %>`, and on a template local named `view` | `before()` names its request by use. `atom` parenthesizes any operator, `!` or `if`, since Rust never warns about parentheses around a receiver. `view` is reserved in templates |
| M3 | Templates compiled with `frozen_string_literal` or annotations (`safe_append='…'` without `.freeze`) crashed Rutile | Both forms of the literal are read. Annotated templates carry Rails' development comments, as development renders them (listed in `gaps.md`) |
| M4 | A page answered `.json` and `Accept: application/json` with HTML; Rails answers 406 | Requests' formats are read as Rails reads them: the `format` param, then an Accept header that isn't a browser's, then the path's extension. An implicit render for a request that doesn't take HTML is UnknownFormat (406); an explicit one is MissingTemplate (500). A render whose format came from Accept gets `Vary: Accept` |
| M5 | An HTML request's error got the JSON error page | Errors follow Rails' exceptions app. A JSON request gets JSON. Anything else gets the app's `public/<status>.html` (embedded at build, the locale's first) or an empty HTML page |
| M6 | Pages had none of Rails' default headers (X-Frame-Options and the rest) | `config.action_dispatch.default_headers` is introspected and added to every controller response |
| M7 | `link_to`'s `method:`, `remote:`, `data:`, `href:` and boolean attributes came out verbatim, and a nil name was empty | Those options are refused. A nil name shows the href, as in Rails |
| M8 | A session past 4 KB was sent anyway, and browsers drop it | CookieOverflow, a 500, as Rails' encrypted jar raises |
| M9 | `queue_name_prefix` baked the build's environment into queue names | Refused |
| M10 | The worker takes jobs of classes it doesn't have, delaying them by the retry backoff | Kept, as Sidekiq does without the class. The deploy guide says to give the Rust worker queues whose jobs it has |
| M11 | Redis had no timeouts and no reconnect, and the worker exited on a Redis error | Redis-client's timeouts: a second to connect, read or write, plus a blocking command's own. A failed connection is reconnected, and the command runs once more. The worker waits and tries again, and a failed job waits until the retry set has it |
| L1 | A non-UTF-8 member of the retry set made the poller spin | Members move byte for byte |
| L2 | `retry: false`, `retry: N`, `dead: false`, `retry_queue`, the dead set's limits and the schedule set differed from Sidekiq | Each as Sidekiq has it; the worker also polls `schedule` |
| L3 | A NaN or Infinity Float argument was enqueued as null | JSON::GeneratorError, as Rails raises |
| L4 | A namespaced job failed in rustfmt | Refused |
| L5 | `shop_product_path("")` gave `/shop/` | A missing key, as Rails' UrlGenerationError |
| L6 | `cookies` compiled in an API controller without `ActionController::Cookies` | Refused |
| L7 | A hash, array or bignum Rails put in the session is a 500 when read | Listed in `gaps.md` |
| L8 | Cookie names were URL-unescaped | Taken as they are, as Rack 3.2 does |
| L9 | A cookie holding `i64::MAX` overflowed on `+ 1` | Overflow is a 500 everywhere, where Ruby makes a Bignum (listed since 0.5) |
| L10 | The server started without `SECRET_KEY_BASE`, then failed on every session | It won't start, as Rails won't boot |
| L11 | `rediss://` and `unix://` failed only at the first enqueue | They fail at startup, for apps with jobs |
| L12 | Statuses the reason table lacked read "Unknown" | Rack's whole table |
| L13 | An extra argument ran where Ruby raises ArgumentError | `perform` checks the count first |
