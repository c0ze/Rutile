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

31 store integration tests pass on Rails and on the Rust build, and the blog's 17 and the tracker's 24 still do.

## The review

Pending.
