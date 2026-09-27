# Middleware and Errors

A Rails response passes through middleware the app never calls by name: the exceptions app, the SSL middleware, the default headers, the cookie and session middleware. The binary does what those do, as far as the app can observe it. Rutile reads the app's settings at introspection and writes them into `src/routes.rs`; RustOnRails' [router](https://github.com/c0ze/RustOnRails/blob/main/src/http/router.rs) applies them.

The store's generated router:

```rust
Router::new()
    .session_store("_store_session")
    .default_headers(&[
        ("X-Frame-Options", "SAMEORIGIN"),
        ("X-XSS-Protection", "0"),
        ("X-Content-Type-Options", "nosniff"),
        ("X-Permitted-Cross-Domain-Policies", "none"),
        ("Referrer-Policy", "strict-origin-when-cross-origin"),
    ])
    // GET /products/stats(.:format) products#stats
    .get(
        "/products/stats(.:format)",
        action("stats", ProductsController::stats),
    )
```

The settings come from the environment `rutile build` introspects (`--env`, development by default). Build in the environment whose settings you want.

## Unrescued errors

An error that no `rescue_from` handles gets the status Rails' `rescue_responses` gives it:

| Error | Status |
|---|---|
| `ActiveRecord::RecordNotFound` | 404 |
| `ActiveRecord::RecordInvalid`, `ActiveRecord::RecordNotSaved` | 422 |
| `ActionController::ParameterMissing` | 400 |
| `ActionController::UnknownFormat` | 406 |
| anything else, including a panic | 500 |

Then the exceptions app answers in the request's format:

- A JSON request gets Rails' JSON page: `{"status":404,"error":"Not Found"}`.
- Anything else gets the app's `public/<status>.html`, preferring `public/<status>.<locale>.html` for the default locale, or an empty `text/html` page when the app has none.

A request is JSON when its `format` param is `json`; without one, when the first type of an `Accept` header Rails reads is a JSON type (`application/json`, `text/x-json`, `application/jsonrequest`); without that, when the path ends in `.json`. Rails ignores a browser's `Accept` (a list with `*/*` among other types) unless the request is an XHR, and so does the binary.

The public pages are read at build time and compiled into `src/routes.rs`:

```rust
.public_page(404, "<h1>Not \"here\"</h1>\n").public_page(500, "<h1>Oops</h1>")
```

As in Rails, an error page carries no cookies (the cookie and session middleware never see the response, so a session written before the error isn't saved) and none of the default headers. Under `force_ssl` it does carry HSTS.

Failures outside the app take the same path: a handler that panics, and a request that arrives when the database can't be reached, are both 500s through the exceptions app, with HSTS under `force_ssl`. With no database, the format comes from the query's `format`, then the body's, then `Accept` and the extension, since there's no route to read it from.

Two more errors come from routing, as in Rails: no matching route is a 404, and a body that claims to be JSON and doesn't parse is a 400 once a route matches, before the action runs.

An error that reaches the top of an action is logged to standard error as `METHOD PATH failed: error`.

## rescue_from

`rescue_from` compiles to the controller's `rescue` method, one arm per handler, the last registered first, as Rails tries them:

```ruby
class ApplicationController < ActionController::API
  rescue_from ActiveRecord::RecordNotFound, with: :not_found
  rescue_from ActiveRecord::RecordInvalid, with: :invalid

  private

  def not_found
    render json: { error: "not found" }, status: :not_found
  end

  def invalid(error)
    render json: error.record.errors, status: :unprocessable_content
  end
end
```

```rust
fn rescue(&mut self, req: &mut Request, error: Error) -> Result<Response> {
    match error {
        // rescue_from ActiveRecord::RecordInvalid, with: :invalid
        Error::RecordInvalid(error) => application::invalid(req, error),
        // rescue_from ActiveRecord::RecordNotFound, with: :not_found
        Error::RecordNotFound { .. } => application::not_found(req),
        other => Err(other),
    }
}
```

The exceptions it handles: `ActiveRecord::RecordNotFound`, `RecordInvalid`, `RecordNotSaved`, `RecordNotDestroyed` and `ActionController::ParameterMissing`. A handler may take the exception only for `RecordInvalid`, whose `error.record.errors` renders as in Rails. Handlers must be methods of the controller or of `ApplicationController`.

Refused: other exception classes, `rescue_from ... do` blocks, a handler taking the exception for anything but `RecordInvalid`, and handlers defined elsewhere. See [Controllers and Routes](Controllers-and-Routes.md).

## force_ssl and assume_ssl

Rails 8's production default is `config.assume_ssl = true` with `config.force_ssl = true`, for TLS ended at a proxy. Behind `assume_ssl` every request counts as HTTPS, so `force_ssl` never redirects; it adds HSTS and marks cookies secure. That's what the binary does:

```rust
.force_ssl()
```

- Every response the app gives, error pages included, gets `Strict-Transport-Security: max-age=63072000; includeSubDomains`.
- Every `Set-Cookie` without `secure` gets `; secure`, the session cookie and plain cookies alike.

Refused:

- `force_ssl` without `assume_ssl`: Rails would redirect plain HTTP to HTTPS, which the binary doesn't (`force_ssl without assume_ssl (redirecting plain HTTP)`).
- `ssl_options` other than Rails' defaults, such as `hsts: false`, another HSTS age, or `redirect: { exclude: ... }` (`ssl_options other than Rails' defaults`).

## Default headers

`config.action_dispatch.default_headers` go on every response a controller gives, as the list above shows for Rails 8.1's defaults. An app's own list replaces them. Error pages don't get them.

The binary doesn't add Rack's `ETag` or `Cache-Control`, so a conditional GET is never a 304. `rutile verify` doesn't compare responses with Rails': it hands the binary's status, headers (all but the connection's own), each `Set-Cookie` and body to the app's integration tests, and their assertions are the check.

## Vary: Accept

When the format of a render came from the `Accept` header (no `format` param, and an `Accept` Rails reads), the response carries `Vary: Accept`, as Rails' does. A browser's `Accept` isn't read, so a page it gets has no `Vary`.

## Health check

`get "up" => "rails/health#show"` routes to RustOnRails' `health`, which answers 200 with the green page Rails' `Rails::HealthController` sends to an HTML request.

## Request limits

Some requests are refused before any route is matched, in the part of the binary that plays Puma's role:

| Status | When |
|---|---|
| 400 | A malformed request line or header, a target that isn't a path (`OPTIONS *`, `GET http://host/path`), a bad `Content-Length`, both `Content-Length` and `Transfer-Encoding`, a malformed chunk |
| 408 | The headers took longer than `HEADER_TIMEOUT`, or the body longer than `BODY_TIMEOUT` plus a second for each `MIN_RATE` bytes |
| 413 | A body over `MAX_BODY_BYTES`: a `Content-Length` over it before any of the body is read, a chunked body at the chunk that would take it past, after the earlier chunks were read |
| 431 | A request line and headers over 16 KiB |
| 501 | A transfer coding other than `chunked` |
| 503 | More than `MAX_CONNECTIONS` connections open |
| 505 | An HTTP version other than 1.0 and 1.1 |

These stay plain: the body is the JSON error page (`{"status":413,"error":"Content Too Large"}`) whatever the request asked for, with no HSTS, no default headers and no public page, and the connection is closed. They're answered in the server's connection threads before the request reaches the app, the layer Puma occupies under Rails, so Rails' middleware has no part in them. The limits and their variables are on [Configuration](Configuration.md); how the server enforces them is on [Runtime](Runtime.md).
