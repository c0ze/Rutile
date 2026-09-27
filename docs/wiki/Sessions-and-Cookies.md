# Sessions and Cookies

A compiled app keeps its session in Rails' cookie store, in the same encrypted cookie Rails writes. With the same `SECRET_KEY_BASE`, a cookie Rails wrote is read by the binary and one the binary wrote is read by Rails, so both can serve one user during a migration. Plain cookies (`cookies[:name]`) work too.

Since 0.10.0. The Rust side is [src/http/session.rs](https://github.com/c0ze/RustOnRails/blob/main/src/http/session.rs), [src/http/cookies.rs](https://github.com/c0ze/RustOnRails/blob/main/src/http/cookies.rs) and [src/http/encryptor.rs](https://github.com/c0ze/RustOnRails/blob/main/src/http/encryptor.rs); the compiler side is [lib/rutile/build/sessions.rb](../../lib/rutile/build/sessions.rb) and the session part of [lib/rutile/build/routes_file.rb](../../lib/rutile/build/routes_file.rb).

## An example

The store keeps a cart in the session ([carts_controller.rb](../../examples/store/app/controllers/carts_controller.rb)). It's an API app, so it adds the cookie middleware and the store itself:

```ruby
# config/application.rb
config.middleware.use ActionDispatch::Cookies
config.middleware.use ActionDispatch::Session::CookieStore, key: "_store_session"
```

```ruby
class CartsController < ApplicationController
  include ActionController::Cookies

  def add
    product = Product.find(params[:product_id])
    quantity = session[:product_id] == product.id ? session[:quantity].to_i : 0
    session[:product_id] = product.id
    session[:quantity] = quantity + params.fetch(:quantity, 1).to_i
    session[:shopper] = params[:shopper] if params[:shopper].present?
    cookies[:visits] = (cookies[:visits].to_i + 1).to_s
    render json: { product_id: product.id, quantity: session[:quantity] }
  end

  def clear
    reset_session
    head :no_content
  end
end
```

The generated code ([carts.rs](https://github.com/c0ze/RustOnRails/blob/main/examples/store/src/controllers/carts.rs)):

```rust
let product = Product::find(&mut req.ctx, req.params.value("product_id")?)?;
let value = req.session.get("product_id")?;
let quantity = if value.equals(&Value::from(req.ctx[product].id)) {
    req.session.get("quantity")?.to_i()?
} else {
    0
};
let id = req.ctx[product].id;
req.session.set("product_id", Value::from(id))?;
// ...
let value_2 = (Value::from(req.cookies.get("visits")).to_i()? + 1).to_string();
req.cookies.set("visits", value_2);
```

and `reset_session` is `req.session.reset()?`. The store's [session_test.rb](../../examples/store/test/integration/session_test.rb) hands a cookie Rails wrote in-process to the binary, and the binary's cookie back to Rails.

The cookie store's settings go into `src/routes.rs`:

```rust
Router::new()
    .session_store("_store_session")
```

## The cookie

RustOnRails reads and writes the cookie as Rails 8.1's encrypted cookie jar does with its defaults:

- The key is derived from `SECRET_KEY_BASE` with PBKDF2-SHA256, salt `authenticated encrypted cookie`, 1000 iterations.
- The session is JSON, wrapped in Rails' metadata envelope with the purpose `cookie.<name>`, and sealed with AES-256-GCM. The cookie value is `base64(ciphertext)--base64(iv)--base64(tag)`, URL-escaped.
- A cookie that doesn't decrypt, was sealed for another cookie name, has expired, or holds no `session_id` is treated as no session, as Rails treats it.
- A cookie over 4096 bytes raises `ActionDispatch::Cookies::CookieOverflow`, so the request is a 500, as in Rails.

The session loads when it's written, or when it's read and the request has a session cookie. A session that loaded is sent back re-encrypted in `Set-Cookie`; one that never loaded sends nothing, so a request that neither reads nor writes the session sets no cookie.

An app with a session store won't start without `SECRET_KEY_BASE`, as Rails won't:

```
SECRET_KEY_BASE is not set, and the app's session cookie needs it
```

Use the Rails app's own secret. See [Configuration](Configuration.md).

## What the session holds

| Ruby | Compiles to | Notes |
|---|---|---|
| `session[:key]` | `req.session.get("key")?` | A `Value`: nil, true, false, an Integer, a Float or a String |
| `session[:key] = value` | `req.session.set("key", value)?` | See below for what `value` may be |
| `session.delete(:key)` | `req.session.delete("key")?` | Gives what the key held |
| `reset_session` | `req.session.reset()?` | An empty session under a new session id |

The key must be a literal Symbol or String. A value read from the session is a `Value`, since the cookie can hold any JSON scalar; operations on it dispatch at run time ([Value Fallback](Value-Fallback.md)).

A value written may be nil, a boolean, an Integer, a Float, a String, a Time, a Date, or a `Value` (a param, for one). It's stored as its JSON, as Rails' JSON serializer stores it:

- nil leaves the key out of the cookie.
- A Time or a Date stays a Time or a Date for the rest of the request, and becomes a String in the cookie, so a later request reads a String. Rails behaves the same way.

Refused:

- a record, a relation, an array or a hash as a session value (`keeping ... in the session`);
- a Symbol as a session value, which JSON would give back as a String;
- a key that isn't a literal.

A session cookie that Rails wrote with a hash or an array in it raises when that key is read (a 500), since a `Value` holds scalars only.

## Plain cookies

| Ruby | Compiles to |
|---|---|
| `cookies[:name]` | `Value::from(req.cookies.get("name"))`: the String, or nil |
| `cookies[:name] = "value"` | `req.cookies.set("name", ...)` |

The value assigned must be a String or a `Value`, which is written as its `to_s`. Cookies are parsed as Rack 3.2 parses them: values are URL-unescaped, names are taken as they are, and the first of a repeated name wins. A cookie set to the value the request already carries isn't sent back, as Rails' jar does.

A plain cookie is written with `path=/` and the app's `cookies_same_site_protection` (Rails' `lax` by default). It isn't `httponly`, and it's `secure` only under `force_ssl` ([Middleware and Errors](Middleware-and-Errors.md)). For example:

```
Set-Cookie: visits=3; path=/; samesite=lax
```

In an API controller (`ActionController::API`), `cookies` exists only with `include ActionController::Cookies`, as in Rails. Without it the build refuses the call:

```
cookies in a controller without ActionController::Cookies isn't supported yet
```

## Cookie options

The session cookie keeps the store's options. Rails 8.1's defaults (`path: "/"`, `httponly`, not `secure`, `samesite=lax`) produce `.session_store("_store_session")`. Anything else writes the options out:

```ruby
config.middleware.use ActionDispatch::Session::CookieStore, key: "_store_session", secure: true, same_site: :strict
```

```rust
.session_store_with("_store_session", CookieOptions { path: "/", secure: true, httponly: true, same_site: Some("strict").map(str::to_string) })
```

Attributes are written in Rack's order: `path`, `secure`, `httponly`, `samesite`.

`same_site` may be `:lax`, `:strict`, `:none` or nil (no attribute). Without its own `same_site:`, the session cookie takes the app's `config.action_dispatch.cookies_same_site_protection`, which also applies to plain cookies. A non-default value becomes `.cookies_same_site(Some("strict"))` in `src/routes.rs`.

## What's refused

Each of these stops `rutile build` with a message; `rutile check` lists them all.

- **Other session stores.** A call to `session` in an app on the cache store, the Active Record store or any store but `CookieStore` is refused (`a session in ActionDispatch::Session::CacheStore`), and so is `session` in an app with no store (`session without a session store`).
- **Session cookie options** `domain:` and `expire_after:`.
- **A cookie format other than Rails 8's default.** The runtime reads only what Rails writes by default, so the build compares the app's settings and refuses any difference: a serializer other than `:json` (`:marshal`, `:hybrid`), unauthenticated encryption, a cipher other than `aes-256-gcm`, another salt, cookies without purpose metadata, cookie rotations, or a key digest other than SHA256. The message names the setting: `the session cookie's serializer "marshal"`, `the session cookie's rotations 1`.
- **SameSite decided per request**: a Proc as `cookies_same_site_protection` or as the store's `same_site:`.
- **Signed and encrypted cookie jars** (`cookies.signed`, `cookies.encrypted`), `cookies.permanent` and `cookies.delete`.
- **Options on a plain cookie** (`cookies[:name] = { value: ..., expires: ... }`): only a String value compiles.
- **`flash`.**
- **Other session methods**: `session.clear`, `session.to_hash`, `session.key?` and the rest; only `[]`, `[]=` and `delete` compile.

The full list of what's refused elsewhere is on [Limitations](Limitations.md).
