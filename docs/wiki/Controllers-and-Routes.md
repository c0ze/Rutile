# Controllers and Routes

Each controller becomes `src/controllers/<name>.rs`: a struct whose fields are the controller's instance variables, a `Controller` impl that holds `wrap_parameters`, the `before_action` chain and the `rescue_from` handlers, and then the actions and the private methods they call. `config/routes.rb` becomes `src/routes.rs`, in the order Rails matches it.

This page covers JSON controllers (`ActionController::API`, and `render json:` anywhere). Full-stack controllers that render ERB templates are on [Views](Views.md); `session` and `cookies` are on [Sessions and Cookies](Sessions-and-Cookies.md); what happens to an exception nobody rescues is on [Middleware and Errors](Middleware-and-Errors.md).

## Actions

An action is a public method without parameters that ends in `render` or `head`, possibly in each branch of an `if`. It becomes a method taking the request and returning a `Response`.

```ruby
def update
  if @post.update(post_params)
    render json: @post
  else
    render json: @post.errors, status: :unprocessable_content
  end
end
```

```rust
// app/controllers/posts_controller.rb:22
pub fn update(&mut self, req: &mut Request) -> Result<Response> {
    let post = self.post.ok_or(Error::Nil { what: "update" })?;
    let attributes = self.post_params(req)?;
    req.ctx.assign(post, &attributes)?;
    if req.ctx.save(post)? {
        Ok(Response::json(status::OK, AsJson::<Post>::new().render_option(&mut req.ctx, self.post)?))
    } else {
        Ok(Response::json(
            status::UNPROCESSABLE_CONTENT,
            errors_json(req.ctx.errors(self.post.ok_or(Error::Nil { what: "errors" })?)),
        ))
    }
}
```

`@post` may be nil in Ruby, so it's an `Option`, and calling a method on nil is the same error Ruby raises. `post_params` runs once, and the record it updates is the one it saves. Arguments run in Ruby's order: the receiver, then the arguments left to right.

Refused: an action with parameters, a `render` or `head` anywhere but at the end, an action that doesn't end in one, and a namespaced controller (`Admin::PostsController`).

## Rendering

`render json:` takes a record, a relation, a record that may be nil (rendered as `null`), a record's `errors`, an array a block or `pluck` made, a hash literal, the hash `as_json` gives, or a param. `status:` is a symbol or an Integer; `head` takes one of either.

```ruby
render json: { error: "not found" }, status: :not_found
render json: comment, status: :created
head :no_content
head :forbidden
```

```rust
Ok(Response::json(status::NOT_FOUND, json!({ "error": "not found" })))
Ok(Response::json(status::CREATED, AsJson::<Comment>::new().render(&mut req.ctx, comment)?))
Ok(Response::head(status::NO_CONTENT))
Ok(Response::head(403))
```

The status symbols are `ok`, `created`, `accepted`, `no_content`, `moved_permanently`, `found`, `see_other`, `not_modified`, `bad_request`, `unauthorized`, `forbidden`, `not_found`, `conflict`, `gone`, `unprocessable_content` (and `unprocessable_entity`), `too_many_requests`, `internal_server_error` and `service_unavailable`.

A relation loads once and renders each record; `as_json` options apply as in [Models](Models.md):

```ruby
render json: posts.as_json(include: { user: { only: %i[id name] } })
```

```rust
let records = posts.load(&mut req.ctx)?;
Ok(Response::json(
    status::OK,
    AsJson::<Post>::new()
        .include(&Post::USER, AsJson::<User>::new().only(&["id", "name"]))
        .render_all(&mut req.ctx, &records)?,
))
```

A hash literal is `json!`, with its values read in Ruby's order. Its keys are Symbols or Strings; a hash with both `"a"` and `:a` is refused, since Rails' JSON encoder raises on the pair. A param renders as Rails would: a String as it is.

Refused in a JSON controller: `render` without `json:`, other `render` options (`plain:`, `location:`, ...), an unknown status symbol, `redirect_to`, an array of Floats (serde writes `1e20` where Ruby's JSON writes `1.0e+20`), and an array of records or hashes that may hold nil.

## Instance variables

Each instance variable is a field `Option<T>` on the controller's struct, typed by what's assigned to it.

```ruby
def set_post
  @post = Post.find(params[:id])
end
```

```rust
#[derive(Default)]
pub struct PostsController {
    post: Option<Handle<Post>>,
}

fn set_post(&mut self, req: &mut Request) -> Result<()> {
    self.post = Some(Post::find(&mut req.ctx, req.params.value("id")?)?);
    Ok(())
}
```

Reading one gives the value or nil. A String field is cloned out, since the controller is borrowed. Refused: assigning `nil` to an instance variable, one instance variable holding two types, reading one before anything assigns it, and instance variables in a model or a scope.

## params

| Ruby | Rust | Gives |
|---|---|---|
| `params[:id]` | `req.params.value("id")?` | a param (a `Value`), nil when absent |
| `params.fetch(:page, 1)` | `req.params.fetch("page", 1)?` | the param, or the literal default when the key is absent |
| `params.require(:user).permit(:name, :email)` | `req.params.require("user")?.permit(&["name", "email"])` | attributes |
| `params.expect(post: %i[title body])` | `req.params.expect("post", &["title", "body"])?` | attributes |
| `request.headers["X-Api-Token"]` | `req.header("X-Api-Token")` | a String or nil |

A param is a `Value`: nil, a boolean, a number or a String, whatever the request sent. Its operators follow Ruby at run time ([Value Fallback](Value-Fallback.md)), and `to_s`, `to_i`, `nil?`, `present?` and `blank?` work on it:

```ruby
def page
  [params.fetch(:page, 1).to_i, 1].max
end
```

```rust
fn page(&mut self, req: &mut Request) -> Result<i64> {
    Ok(i64::max(req.params.fetch("page", 1)?.to_i()?, 1))
}
```

`require` raises `ParameterMissing` when the key is absent, empty or not a hash; `expect` also when nothing permitted is there. `permit` keeps the listed keys that hold scalars and drops the rest, as Rails does by default. The attributes they give go to `Model.new`, `create`, `create!`, `update` and `update!` ([Models](Models.md)).

Refused: a key that isn't a Symbol (`params["id"]`), `fetch` without a default or with a default that isn't a literal (a Symbol default too, since a Value holds it as a String), nested permits (`permit(tags: [])`, `expect(post: [:title, { tags: [] }])`), and a helper that returns `params` itself. A param holding an array or a hash raises when it's read as a value (a 500), where Rails hands it on: a Value holds scalars only.

### wrap_parameters

Rails wraps a JSON body under the controller's model name. The compiled controller does the same, with the attribute names Rails resolved:

```rust
fn wrap_parameters() -> Option<(&'static str, Option<&'static [&'static str]>)> {
    Some(("post", Some(&["body", "comments_count", "created_at", "id", "published_at", "status", "title", "updated_at", "user_id"])))
}
```

Wrapping for formats other than JSON, and `exclude:`, are refused.

## before_action

Filters come from the chain Rails resolved, with `only:` and `except:` as the action lists Rails keeps and `skip_before_action` already applied. A filter is a method without parameters.

```ruby
before_action :set_post, only: %i[show update destroy]
```

```rust
fn before(&mut self, req: &mut Request, action: &str) -> Result<Option<Response>> {
    // before_action :set_post
    if matches!(action, "destroy" | "show" | "update") {
        self.set_post(req)?;
    }
    Ok(None)
}
```

A filter that renders or heads halts the chain with its response. The render must be the filter's last statement, possibly under `if` or `unless`:

```ruby
def authenticate
  @current_user = User.find_by(api_token: request.headers["X-Api-Token"].to_s)
  head :unauthorized unless @current_user
end
```

```rust
// before_action :authenticate (app/controllers/application_controller.rb)
if let Some(response) = self.authenticate(req)? {
    return Ok(Some(response));
}
```

```rust
fn authenticate(&mut self, req: &mut Request) -> Result<Option<Response>> {
    let header = req.header("X-Api-Token").unwrap_or_default();
    self.current_user = User::find_by(&mut req.ctx, "api_token", header)?;
    if self.current_user.is_some() {
        Ok(None)
    } else {
        Ok(Some(Response::head(401)))
    }
}
```

`skip_before_action :authenticate, only: :create` comes out as `if !matches!(action, "create") { ... }`.

Refused: `after_action` and `around_action`, a filter given as a block or a lambda, conditions other than `only:` and `except:` (`if: :admin?`), a filter from outside the app, a filter with parameters, a render or head before a filter's last statement, and calling a filter that renders from another method (its response would be dropped and the caller would carry on).

## rescue_from

Handlers become the arms of `Controller::rescue`. Rails tries the handler registered last first, and so does the match:

```ruby
rescue_from ActiveRecord::RecordNotFound, with: :not_found
rescue_from ActiveRecord::RecordInvalid, with: :invalid
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

The exceptions that compile are `ActiveRecord::RecordNotFound`, `ActiveRecord::RecordInvalid`, `ActiveRecord::RecordNotSaved`, `ActiveRecord::RecordNotDestroyed` and `ActionController::ParameterMissing`. A handler is a method in the controller or in `ApplicationController`, and it renders or heads. It may take the exception only for `RecordInvalid`, whose `record.errors` it can render:

```ruby
def invalid(error)
  render json: error.record.errors, status: :unprocessable_content
end
```

```rust
// app/controllers/application_controller.rb:20
pub fn invalid(_req: &mut Request, error: RecordInvalid) -> Result<Response> {
    Ok(Response::json(status::UNPROCESSABLE_CONTENT, errors_json(&error.errors)))
}
```

Refused: other exception classes, a `rescue_from` block, a handler defined anywhere else, a handler taking the exception for another class, other uses of the exception (`error.message`, `render json: error.record`, `errors.full_messages`), and handler parameters other than the exception.

## ApplicationController

What a controller inherits from `ApplicationController`, Rutile compiles into that controller, since Rust has no inheritance:

- its `before_action`s, in the chain Rails resolved;
- its private methods and `attr_reader`s, translated into each controller that calls them;
- its `rescue_from` handlers, which become functions in `src/controllers/application.rs` that every controller calls;
- its constants, looked up after the controller's own, as Ruby does.

```ruby
class ApplicationController < ActionController::API
  before_action :authenticate
  private
  attr_reader :current_user
  # ...
end

class ProjectsController < ApplicationController
  def index
    projects = current_user.projects.active.order(:name)
    # ...
  end
end
```

`current_user` reads the `@current_user` field that `authenticate` set on `ProjectsController`'s own struct. A method defined in the controller wins over `ApplicationController`'s, as in Ruby. A controller that inherits from `ActionController::API` or `ActionController::Base` directly gets none of these.

Refused: instance variables in `ApplicationController`'s rescue handlers (they run as functions, without a controller), and routes to a public method of `ApplicationController` (see below).

## Helpers

A private method an action calls is translated once per controller, the first time something calls it. It returns what its body ends on:

```ruby
def comment_params
  params.expect(comment: %i[user_id body])
end
```

A helper with parameters needs an rbs-inline signature, and its callers' arguments are checked against it ([Types and Signatures](Types-and-Signatures.md)):

```ruby
#: (Integer) -> Integer
def amount(requested)
  [requested, 0].max
end
```

```rust
// app/controllers/products_controller.rb:115
fn amount(&mut self, _req: &mut Request, requested: i64) -> Result<i64> {
    Ok(i64::max(requested, 0))
}
```

Class-body constants become Rust `const`s (`PER_PAGE = 20` is `const PER_PAGE: i64 = 20;`). A constant must be an Integer, String, Symbol or boolean literal, optionally `.freeze`d.

A controller's class body may hold `before_action`, `skip_before_action`, `rescue_from`, `wrap_parameters`, `attr_reader`, `include ActionController::Cookies`, `private`/`protected`/`public`, constants and `def`s (`layout` too on `ActionController::Base`). Anything else (`after_action`, `helper_method`, `include` of another module, ...) is refused.

## Routes

`src/routes.rs` lists every route in the order Rails matches it, one line per verb. `resources`, `resource`, nesting, `shallow:`, `only:`, and `member` and `collection` routes all arrive as the routes Rails built.

```ruby
Rails.application.routes.draw do
  resources :users, only: %i[show create] do
    get :lookup, on: :collection, constraints: ->(request) { request.query_parameters["email"].present? }
  end
  resources :posts do
    resources :comments, only: %i[index create]
  end

  get "up" => "rails/health#show", as: :rails_health_check
end
```

```rust
pub fn routes() -> Router {
    Router::new()
        // ...
        // GET /users/lookup(.:format) users#lookup
        .get("/users/lookup(.:format)", action("lookup", UsersController::lookup))
        .constraint(users_lookup_constraint)
        // POST /users(.:format) users#create
        .post("/users(.:format)", action("create", UsersController::create))
        // GET /users/:id(.:format) users#show
        .get("/users/:id(.:format)", action("show", UsersController::show))
        // ...
        // PATCH /posts/:id(.:format) posts#update
        .patch("/posts/:id(.:format)", action("update", PostsController::update))
        // ...
        // GET /up(.:format) rails/health#show
        .get("/up(.:format)", Box::new(health))
}

// config/routes.rb:3
fn users_lookup_constraint(req: &Request) -> bool {
    req.query.get("email").cloned().is_present()
}
```

A constraint lambda takes the request and returns true or false; it can read `request.query_parameters[...]` and `request.headers[...]`. `rails/health#show` is RustOnRails' health check. Each named route whose path has no optional parts or globs (besides `(.:format)`) also gets a `_path` function in `routes.rs`, which controllers and views can call:

```rust
/// `project_path`: /projects/:id(.:format)
pub fn project_path(id: impl ToParam) -> Result<String> {
    Ok(format!("/projects/{}", path_segment(id, "projects", "show", "id")?))
}
```

Refused:

- a route without a controller: a `redirect` or a `mount`;
- requirements, such as `constraints: { id: /\d+/ }`, and request constraints, such as `constraints: { subdomain: "api" }`;
- a constraint object (a class with `matches?`), and a lambda without one request parameter or that doesn't return true or false;
- `via: :all`, and verbs other than GET, POST, PATCH, PUT and DELETE;
- a namespaced controller (`namespace :admin`), a controller the app doesn't define, and an action the controller doesn't have;
- `ApplicationController` as a route's controller, and an action the controller inherits (a public method of `ApplicationController`) rather than defines in its own file.
