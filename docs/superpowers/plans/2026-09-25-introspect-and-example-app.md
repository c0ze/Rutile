# Example App and `rutile introspect` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the proof-of-concept Rails app (`examples/blog`) and a working `rutile introspect` that boots it and writes a JSON manifest of what Rails built at load time.

**Architecture:** `rutile introspect` (host side, `lib/rutile/introspect.rb`) runs `bin/rails runner lib/rutile/introspect/runner.rb` inside the target app with Bundler's environment stripped, so the app boots with its own Gemfile. The runner loads only Ruby stdlib, Rails, and the files in `lib/rutile/introspect/`; it records scopes as models load, eager-loads the app, asks Rails for its schema, models, routes and controllers, and writes sorted JSON. This is plan 1 of 4 for the PoC; later plans cover the RustOnRails runtime core, `rutile build`, and `rutile verify`, and each gets written when the previous one lands.

**Tech Stack:** Ruby 3.4.9, Rails 8.1.4 (API-only, minimal), PostgreSQL 16.15 via mise (`conda:postgresql`), pg gem 1.6.x (precompiled, bundles libpq), minitest, rake.

**Spec:** `docs/design.md` (sections "Pipeline > 2. Introspect" and "Proof of concept"). Runtime side: `../RustOnRails/docs/design.md`.

## Global Constraints

- Ruby 3.4.9 comes from `~/projects/.mise.toml`; do not add a Ruby pin to this repo.
- Rails is exactly 8.1.4. Callback introspection reads Rails-internal instance variables (`@if`, `@unless`, `ActionFilter#@actions`) and is tied to that version.
- The example app uses PostgreSQL 16.15 from mise, in a throwaway cluster under `tmp/pg`, port 54329 (override with `BLOG_DB_PORT`). Never touch a system Postgres or Docker.
- Files under `lib/rutile/introspect/` run inside the target app: they may require only Ruby stdlib and Rails. No `prism`, no `require_relative` of anything outside that directory.
- The manifest must contain no absolute paths and must be byte-identical across two runs over the same app.
- Code files stay under 200 lines. No mocks or stubs outside `test/`. Never create or overwrite a `.env` file.
- Every commit message ends with a blank line and `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Run Rutile's tests as `bundle exec rake test` from the repo root. Run example-app commands from `examples/blog` in a plain shell (not under `bundle exec`).

## Review Focus

1. **Bundler leaking into the app.** `bundle exec rake test` puts Rutile's Gemfile in the environment; the app must still boot with its own. Pinned by the whole introspection suite (Task 4 onward runs under `bundle exec`) and the CLI end-to-end test in Task 4.
2. **The app fails to boot.** `rutile introspect` must raise with the app's own error output, and must not leave a stale manifest from an earlier run. Test: Task 4 `test_failed_run_raises_and_leaves_no_stale_manifest`.
3. **The app eager-loads at boot** (`CI=1` in the test env). Scopes can't be recorded then; introspection must refuse with a clear message instead of writing a manifest that silently lacks them. Test: Task 7 `test_eager_loaded_app_is_refused`.
4. **Option values JSON can't hold** (Regexp, Range, Class, infinite Float, procs, arbitrary objects). They must become tagged objects, never a crash or a `"#<Proc...>"` string. Tests: Task 6 `serialize_test.rb` and the email-format validator assertion.
5. **Unstable or machine-specific output.** Absolute paths, gem directories or unsorted hashes would make manifests differ between runs and machines. Tests: Task 4 `test_no_machine_specific_paths` and `test_cli_writes_the_same_manifest`, re-run by every later task because they sit in the shared suite.

---

### Task 1: Local Postgres and the example app skeleton

**Files:**
- Create: `mise.toml`
- Create: `lib/rutile/unbundled.rb`
- Create: `rakelib/example.rake`
- Generate: `examples/blog/` (via `rails new`)
- Create: `examples/blog/.gitignore`
- Replace: `examples/blog/config/database.yml`

**Interfaces:**
- Produces: `Rutile.unbundled { ... }` (runs the block without Bundler's environment; used by Tasks 4 and later). Rake tasks `pg:start`, `pg:stop`, `example:db`, `example:test`. Constants `PG_DIR`, `PG_PORT`, `EXAMPLE_APP` in `rakelib/example.rake`.

- [ ] **Step 1: Install Rails 8.1.4**

Run: `gem install rails -v 8.1.4 --no-document && rails _8.1.4_ --version`
Expected: last line `Rails 8.1.4`

- [ ] **Step 2: Pin PostgreSQL for this repo**

Create `mise.toml`:

```toml
[tools]
# PostgreSQL for the example app's throwaway cluster (rake pg:start).
"conda:postgresql" = "16.15"
```

Run: `mise trust && initdb --version`
Expected: `initdb (PostgreSQL) 16.15`

- [ ] **Step 3: Add the Bundler helper**

Create `lib/rutile/unbundled.rb`:

```ruby
module Rutile
  # Runs the block without Bundler's environment, so commands started inside
  # it use the target app's Gemfile instead of Rutile's.
  def self.unbundled(&block)
    defined?(Bundler) ? Bundler.with_unbundled_env(&block) : yield
  end
end
```

- [ ] **Step 4: Add the Postgres and example-app rake tasks**

Create `rakelib/example.rake`:

```ruby
require_relative "../lib/rutile/unbundled"

# A throwaway Postgres cluster under tmp/pg for the example app, using the
# PostgreSQL that mise.toml pins. It never touches a system server.
PG_DIR = File.expand_path("../tmp/pg", __dir__)
PG_PORT = ENV.fetch("BLOG_DB_PORT", "54329")
EXAMPLE_APP = File.expand_path("../examples/blog", __dir__)

def pg_running?
  system("pg_ctl", "-D", PG_DIR, "status", out: File::NULL, err: File::NULL)
end

namespace :pg do
  desc "Start the local Postgres cluster, creating it on first use"
  task :start do
    unless File.exist?(File.join(PG_DIR, "PG_VERSION"))
      sh "initdb", "-D", PG_DIR, "-U", "postgres", "--auth=trust", "--encoding=UTF8", "--no-locale"
    end
    next if pg_running?

    sh "pg_ctl", "-D", PG_DIR, "-l", File.join(PG_DIR, "server.log"), "-w",
       "-o", "-p #{PG_PORT} -k #{PG_DIR} -c listen_addresses=localhost", "start"
  end

  desc "Stop the local Postgres cluster"
  task :stop do
    sh "pg_ctl", "-D", PG_DIR, "-m", "fast", "stop" if pg_running?
  end
end

namespace :example do
  desc "Create and migrate the example app's test database"
  task db: "pg:start" do
    Dir.chdir(EXAMPLE_APP) do
      Rutile.unbundled { sh({ "RAILS_ENV" => "test" }, "bin/rails", "db:prepare") }
    end
  end

  desc "Run the example app's own test suite"
  task test: :db do
    Dir.chdir(EXAMPLE_APP) { Rutile.unbundled { sh "bin/rails", "test" } }
  end
end
```

- [ ] **Step 5: Generate the app**

Run from the repo root:

```bash
rails _8.1.4_ new examples/blog --api --minimal --database=postgresql --skip-git
```

Expected: ends with `Bundle complete!` and the gem list includes `pg 1.6.x` for `x86_64-linux`.

- [ ] **Step 6: Point the app at the local cluster**

Replace `examples/blog/config/database.yml` with:

```yaml
default: &default
  adapter: postgresql
  encoding: unicode
  host: <%= ENV.fetch("BLOG_DB_HOST", "localhost") %>
  port: <%= ENV.fetch("BLOG_DB_PORT", 54329) %>
  username: <%= ENV.fetch("BLOG_DB_USER", "postgres") %>
  max_connections: <%= ENV.fetch("RAILS_MAX_THREADS") { 5 } %>

development:
  <<: *default
  database: blog_development

test:
  <<: *default
  database: blog_test

production:
  <<: *default
  database: blog_production
  password: <%= ENV["BLOG_DATABASE_PASSWORD"] %>
```

- [ ] **Step 7: Ignore generated state**

`--skip-git` also skips `.gitignore`. Create `examples/blog/.gitignore`:

```gitignore
/.bundle
/log/*
!/log/.keep
/tmp/*
!/tmp/.keep
/config/master.key
```

- [ ] **Step 8: Create the test database and run the (empty) suite**

Run: `bundle exec rake example:test`
Expected: `initdb` output on the first run, `server started`, `Created database 'blog_test'`, then `0 runs, 0 assertions, 0 failures, 0 errors, 0 skips`.

Run: `psql -h localhost -p 54329 -U postgres -Atc "select datname from pg_database where datname like 'blog%'"`
Expected: `blog_test`

- [ ] **Step 9: Commit**

```bash
git add mise.toml lib/rutile/unbundled.rb rakelib/example.rake examples/blog
git diff --cached --name-only | grep -E 'master\.key$|^examples/blog/(log|tmp)/[^.]' && echo "STOP: ignored files staged"
git commit -m "Add the example Rails app and a local Postgres cluster" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

Expected: the `grep` prints nothing (`log/.keep` and `tmp/.keep` are fine) and the commit succeeds.

---

### Task 2: Example app models

**Files (all under `examples/blog/`):**
- Generate then replace: `db/migrate/*_create_users.rb`, `db/migrate/*_create_posts.rb`, `db/migrate/*_create_comments.rb`
- Replace: `app/models/user.rb`, `app/models/post.rb`, `app/models/comment.rb`
- Replace: `test/fixtures/users.yml`, `test/fixtures/posts.yml`, `test/fixtures/comments.yml`
- Replace: `test/models/user_test.rb`, `test/models/post_test.rb`, `test/models/comment_test.rb`
- Generated by migrate: `db/schema.rb`

**Interfaces:**
- Produces (used by Tasks 3, 5–7): tables `users`, `posts`, `comments`; models `User`, `Post`, `Comment` with the exact file contents below. Tasks 6–7 assert on line numbers in these files, so keep them byte-for-byte.

- [ ] **Step 1: Generate the models**

Run from `examples/blog`:

```bash
bin/rails generate model User name:string email:string:uniq
bin/rails generate model Post user:references title:string body:text status:integer published_at:datetime comments_count:integer
bin/rails generate model Comment post:references user:references body:text
```

- [ ] **Step 2: Replace the migrations**

Replace `db/migrate/*_create_users.rb` (keep the generated filename) with:

```ruby
class CreateUsers < ActiveRecord::Migration[8.1]
  def change
    create_table :users do |t|
      t.string :name, null: false
      t.string :email, null: false

      t.timestamps
    end
    add_index :users, :email, unique: true
  end
end
```

Replace `db/migrate/*_create_posts.rb` with:

```ruby
class CreatePosts < ActiveRecord::Migration[8.1]
  def change
    create_table :posts do |t|
      t.references :user, null: false, foreign_key: true
      t.string :title, null: false
      t.text :body
      t.integer :status, null: false, default: 0
      t.datetime :published_at
      t.integer :comments_count, null: false, default: 0

      t.timestamps
    end
  end
end
```

Replace `db/migrate/*_create_comments.rb` with:

```ruby
class CreateComments < ActiveRecord::Migration[8.1]
  def change
    create_table :comments do |t|
      t.references :post, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.text :body, null: false

      t.timestamps
    end
  end
end
```

- [ ] **Step 3: Migrate**

Run from `examples/blog` (Postgres must be up: `bundle exec rake pg:start` from the repo root):

```bash
bin/rails db:prepare
```

Expected: `Created database 'blog_development'`, three `== Create...: migrated` blocks, and a new `db/schema.rb` with `create_table "posts"` containing `t.integer "status", default: 0, null: false`.

- [ ] **Step 4: Write the fixtures**

Replace `test/fixtures/users.yml`:

```yaml
alice:
  name: Alice
  email: alice@example.com

bob:
  name: Bob
  email: bob@example.com
```

Replace `test/fixtures/posts.yml`:

```yaml
published_old:
  user: alice
  title: Old news
  body: First post
  status: published
  published_at: <%= 3.days.ago %>
  created_at: <%= 3.days.ago %>
  comments_count: 1

published_new:
  user: bob
  title: Fresh news
  body: Second post
  status: published
  published_at: <%= 1.day.ago %>
  created_at: <%= 1.day.ago %>

draft:
  user: alice
  title: Work in progress
  body: Not yet
  status: draft
```

Replace `test/fixtures/comments.yml`:

```yaml
first:
  post: published_old
  user: bob
  body: Nice one
```

- [ ] **Step 5: Write the failing model tests**

Replace `test/models/user_test.rb`:

```ruby
require "test_helper"

class UserTest < ActiveSupport::TestCase
  test "requires name and email" do
    user = User.new
    assert_not user.valid?
    assert_includes user.errors[:name], "can't be blank"
    assert_includes user.errors[:email], "can't be blank"
  end

  test "normalizes email before validation" do
    user = User.create!(name: "Carol", email: "  Carol@Example.COM ")
    assert_equal "carol@example.com", user.email
  end

  test "rejects a malformed email" do
    user = User.new(name: "Dan", email: "not-an-email")
    assert_not user.valid?
    assert_includes user.errors[:email], "is invalid"
  end

  test "email is unique after normalizing" do
    user = User.new(name: "Alice 2", email: "ALICE@example.com")
    assert_not user.valid?
    assert_includes user.errors[:email], "has already been taken"
  end
end
```

Replace `test/models/post_test.rb`:

```ruby
require "test_helper"

class PostTest < ActiveSupport::TestCase
  test "title is required and at most 200 characters" do
    post = Post.new(user: users(:alice), title: "")
    assert_not post.valid?
    assert_includes post.errors[:title], "can't be blank"

    post.title = "x" * 201
    assert_not post.valid?
    assert_includes post.errors[:title], "is too long (maximum is 200 characters)"
  end

  test "an unknown status is a validation error, not an exception" do
    post = Post.new(user: users(:alice), title: "Hi", status: "archived")
    assert_not post.valid?
    assert_includes post.errors[:status], "is not included in the list"
  end

  test "publishing stamps published_at once" do
    post = posts(:draft)
    assert_nil post.published_at

    post.update!(status: :published)
    stamped = post.reload.published_at
    assert_not_nil stamped

    post.update!(title: "Edited")
    assert_equal stamped, post.reload.published_at
  end

  test "drafts never get published_at" do
    post = Post.create!(user: users(:bob), title: "Still a draft")
    assert_nil post.published_at
  end

  test "visible.recent lists published posts newest first" do
    assert_equal [posts(:published_new), posts(:published_old)], Post.visible.recent.to_a
  end
end
```

Replace `test/models/comment_test.rb`:

```ruby
require "test_helper"

class CommentTest < ActiveSupport::TestCase
  test "body is required" do
    comment = Comment.new(post: posts(:published_old), user: users(:bob))
    assert_not comment.valid?
    assert_includes comment.errors[:body], "can't be blank"
  end

  test "creating a comment bumps the post's comments_count" do
    post = posts(:published_new)
    assert_difference -> { post.reload.comments_count }, 1 do
      Comment.create!(post: post, user: users(:alice), body: "Agreed")
    end
  end
end
```

- [ ] **Step 6: Run them to see them fail**

Run from `examples/blog`: `bin/rails test test/models`
Expected: FAIL. Errors include `NoMethodError: undefined method 'visible'` and failed assertions on blank validations (the generated models are empty).

- [ ] **Step 7: Write the models**

Replace `app/models/user.rb`:

```ruby
class User < ApplicationRecord
  has_many :posts, dependent: :destroy
  has_many :comments, dependent: :destroy

  before_validation { self.email = email.to_s.strip.downcase }

  validates :name, presence: true
  validates :email, presence: true, uniqueness: true, format: { with: URI::MailTo::EMAIL_REGEXP }
end
```

Replace `app/models/post.rb`:

```ruby
class Post < ApplicationRecord
  belongs_to :user
  has_many :comments, dependent: :destroy

  enum :status, { draft: 0, published: 1 }, validate: true

  validates :title, presence: true, length: { maximum: 200 }

  scope :recent, -> { order(created_at: :desc) }
  scope :visible, -> { where(status: :published) }

  before_save :stamp_published_at, if: :published?

  private

  def stamp_published_at
    self.published_at ||= Time.current
  end
end
```

Replace `app/models/comment.rb`:

```ruby
class Comment < ApplicationRecord
  belongs_to :post
  belongs_to :user

  validates :body, presence: true, length: { maximum: 2000 }

  after_create :bump_post_counter

  private

  def bump_post_counter
    post.increment!(:comments_count)
  end
end
```

- [ ] **Step 8: Run the tests**

Run from `examples/blog`: `bin/rails test test/models`
Expected: `11 runs, ... 0 failures, 0 errors, 0 skips`

- [ ] **Step 9: Commit**

```bash
git add examples/blog
git commit -m "Example app: users, posts and comments models" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Example app JSON API

**Files (all under `examples/blog/`):**
- Replace: `app/controllers/application_controller.rb`
- Create: `app/controllers/users_controller.rb`, `app/controllers/posts_controller.rb`, `app/controllers/comments_controller.rb`
- Replace: `config/routes.rb`
- Create: `test/integration/users_api_test.rb`, `test/integration/posts_api_test.rb`, `test/integration/comments_api_test.rb`

**Interfaces:**
- Consumes: models and fixtures from Task 2.
- Produces (used by Tasks 8–9): routes and the four controllers exactly as below. Task 9 asserts on line numbers in `application_controller.rb` and `posts_controller.rb`.

- [ ] **Step 1: Write the failing integration tests**

Create `test/integration/posts_api_test.rb`:

```ruby
require "test_helper"

class PostsApiTest < ActionDispatch::IntegrationTest
  test "index lists published posts newest first with their author" do
    get posts_path, as: :json
    assert_response :ok

    body = response.parsed_body
    assert_equal [posts(:published_new).id, posts(:published_old).id], body.map { _1["id"] }
    assert_equal({ "id" => users(:bob).id, "name" => "Bob" }, body.first["user"])
  end

  test "show returns the post" do
    get post_path(posts(:draft)), as: :json
    assert_response :ok
    assert_equal "Work in progress", response.parsed_body["title"]
  end

  test "show of a missing post is a JSON 404" do
    get post_path(id: 0), as: :json
    assert_response :not_found
    assert_equal({ "error" => "not found" }, response.parsed_body)
  end

  test "create accepts unwrapped JSON params" do
    assert_difference -> { Post.count }, 1 do
      post posts_path, params: { user_id: users(:alice).id, title: "New", body: "Hello", status: "published" }, as: :json
    end
    assert_response :created
    assert_not_nil response.parsed_body["published_at"]
  end

  test "create with a blank title is a 422 with errors" do
    post posts_path, params: { user_id: users(:alice).id, title: "" }, as: :json
    assert_response :unprocessable_content
    assert_includes response.parsed_body["title"], "can't be blank"
  end

  test "create with an unknown status is a 422, not a 500" do
    post posts_path, params: { user_id: users(:alice).id, title: "Hi", status: "archived" }, as: :json
    assert_response :unprocessable_content
    assert_includes response.parsed_body["status"], "is not included in the list"
  end

  test "update changes the title" do
    patch post_path(posts(:draft)), params: { title: "Done" }, as: :json
    assert_response :ok
    assert_equal "Done", posts(:draft).reload.title
  end

  test "destroy removes the post and its comments" do
    assert_difference -> { Comment.count }, -1 do
      delete post_path(posts(:published_old)), as: :json
    end
    assert_response :no_content
  end
end
```

Create `test/integration/comments_api_test.rb`:

```ruby
require "test_helper"

class CommentsApiTest < ActionDispatch::IntegrationTest
  test "index lists a post's comments oldest first" do
    get post_comments_path(posts(:published_old)), as: :json
    assert_response :ok
    assert_equal [comments(:first).id], response.parsed_body.map { _1["id"] }
  end

  test "create adds a comment and bumps the counter" do
    target = posts(:published_new)
    assert_difference -> { target.reload.comments_count }, 1 do
      post post_comments_path(target), params: { user_id: users(:alice).id, body: "Agreed" }, as: :json
    end
    assert_response :created
  end

  test "comments on a missing post are a JSON 404" do
    get post_comments_path(post_id: 0), as: :json
    assert_response :not_found
  end
end
```

Create `test/integration/users_api_test.rb`:

```ruby
require "test_helper"

class UsersApiTest < ActionDispatch::IntegrationTest
  test "create with nested params" do
    post users_path, params: { user: { name: "Carol", email: "carol@example.com" } }, as: :json
    assert_response :created
    assert_equal "carol@example.com", response.parsed_body["email"]
  end

  test "create with a taken email is a 422" do
    post users_path, params: { user: { name: "Alice", email: "ALICE@example.com" } }, as: :json
    assert_response :unprocessable_content
    assert_includes response.parsed_body["email"], "has already been taken"
  end

  test "show returns the user" do
    get user_path(users(:bob)), as: :json
    assert_response :ok
    assert_equal "Bob", response.parsed_body["name"]
  end

  test "lookup finds a user by email" do
    get lookup_users_path, params: { email: " BOB@example.com " }, as: :json
    assert_response :ok
    assert_equal users(:bob).id, response.parsed_body["id"]
  end

  test "lookup of an unknown email is a JSON 404" do
    get lookup_users_path, params: { email: "nobody@example.com" }, as: :json
    assert_response :not_found
  end
end
```

- [ ] **Step 2: Run them to see them fail**

Run from `examples/blog`: `bin/rails test test/integration`
Expected: FAIL with `NameError: undefined local variable or method 'posts_path'` (no routes yet).

- [ ] **Step 3: Write the routes**

Replace `config/routes.rb`:

```ruby
Rails.application.routes.draw do
  resources :users, only: %i[show create] do
    get :lookup, on: :collection
  end
  resources :posts do
    resources :comments, only: %i[index create]
  end

  get "up" => "rails/health#show", as: :rails_health_check
end
```

- [ ] **Step 4: Write the controllers**

Replace `app/controllers/application_controller.rb`:

```ruby
class ApplicationController < ActionController::API
  rescue_from ActiveRecord::RecordNotFound, with: :not_found

  private

  def not_found
    render json: { error: "not found" }, status: :not_found
  end
end
```

Create `app/controllers/users_controller.rb` (uses the classic `require`/`permit` form on purpose; `PostsController` uses Rails 8's `expect`):

```ruby
class UsersController < ApplicationController
  def show
    render json: User.find(params[:id])
  end

  def lookup
    render json: User.find_by!(email: params[:email].to_s.strip.downcase)
  end

  def create
    user = User.new(user_params)
    if user.save
      render json: user, status: :created
    else
      render json: user.errors, status: :unprocessable_content
    end
  end

  private

  def user_params
    params.require(:user).permit(:name, :email)
  end
end
```

Create `app/controllers/posts_controller.rb`:

```ruby
class PostsController < ApplicationController
  before_action :set_post, only: %i[show update destroy]

  def index
    posts = Post.visible.recent.includes(:user).limit(20)
    render json: posts.as_json(include: { user: { only: %i[id name] } })
  end

  def show
    render json: @post
  end

  def create
    post = Post.new(post_params)
    if post.save
      render json: post, status: :created
    else
      render json: post.errors, status: :unprocessable_content
    end
  end

  def update
    if @post.update(post_params)
      render json: @post
    else
      render json: @post.errors, status: :unprocessable_content
    end
  end

  def destroy
    @post.destroy!
    head :no_content
  end

  private

  def set_post
    @post = Post.find(params[:id])
  end

  def post_params
    params.expect(post: %i[user_id title body status])
  end
end
```

Create `app/controllers/comments_controller.rb`:

```ruby
class CommentsController < ApplicationController
  before_action :set_post

  def index
    render json: @post.comments.order(:created_at)
  end

  def create
    comment = @post.comments.new(comment_params)
    if comment.save
      render json: comment, status: :created
    else
      render json: comment.errors, status: :unprocessable_content
    end
  end

  private

  def set_post
    @post = Post.find(params[:post_id])
  end

  def comment_params
    params.expect(comment: %i[user_id body])
  end
end
```

- [ ] **Step 5: Run the whole app suite**

Run from the repo root: `bundle exec rake example:test`
Expected: `27 runs, ... 0 failures, 0 errors, 0 skips`

- [ ] **Step 6: Commit**

```bash
git add examples/blog
git commit -m "Example app: JSON API for users, posts and comments" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: `rutile introspect` command, manifest header and config

**Files:**
- Create: `lib/rutile/cli.rb`, `lib/rutile/introspect.rb`
- Create: `lib/rutile/introspect/runner.rb`, `lib/rutile/introspect/manifest.rb`, `lib/rutile/introspect/source.rb`, `lib/rutile/introspect/config.rb`
- Modify: `lib/rutile.rb`, `exe/rutile`, `Rakefile`, `test/cli_test.rb`
- Create: `test/introspect_helper.rb`, `test/introspect/manifest_test.rb`
- Create: `docs/manifest.md`

**Interfaces:**
- Consumes: `Rutile.unbundled` (Task 1), `examples/blog` (Tasks 1–3).
- Produces:
  - `Rutile::Introspect.run(app_dir:, env:, out:, vars: {}) -> String` (returns `out`; raises `Rutile::Introspect::Error`)
  - `Rutile::CLI.new(argv, out: $stdout, err: $stderr).run -> Integer` (exit status)
  - `Rutile::Introspect::Manifest.build(app) -> Hash` (later tasks add keys)
  - `Rutile::Introspect::Source.location(path = nil, line = nil) -> Hash | nil`, `.const_location(name)`, `.method_location(owner, name)`, `.app_defined?(klass) -> Boolean`
  - `IntrospectHelper` test module: `IntrospectHelper::APP`, `IntrospectHelper.manifest_text`, `IntrospectHelper.manifest`, instance method `manifest`

- [ ] **Step 1: Write the failing tests**

Create `test/introspect_helper.rb`:

```ruby
require "minitest/autorun"
require "json"
require "tmpdir"
require_relative "../lib/rutile"

# Runs `rutile introspect` against examples/blog once per test process and
# shares the result. Needs the example database; `bundle exec rake test`
# starts Postgres and prepares it first.
module IntrospectHelper
  APP = File.expand_path("../examples/blog", __dir__)

  def self.manifest_text
    @manifest_text ||= begin
      out = File.join(Dir.mktmpdir("rutile"), "manifest.json")
      Rutile::Introspect.run(app_dir: APP, env: "test", out: out)
      File.read(out)
    end
  end

  def self.manifest
    @manifest ||= JSON.parse(manifest_text)
  end

  def manifest = IntrospectHelper.manifest
end
```

Create `test/introspect/manifest_test.rb`:

```ruby
require "fileutils"
require "open3"
require_relative "../introspect_helper"

class ManifestTest < Minitest::Test
  include IntrospectHelper

  EXE = File.expand_path("../../exe/rutile", __dir__)

  def test_header
    assert_equal 1, manifest["manifest_version"]
    assert_equal "8.1.4", manifest["rails_version"]
    assert_equal RUBY_VERSION, manifest["ruby_version"]
  end

  def test_config
    assert_equal(
      { "api_only" => true, "time_zone" => "UTC", "default_locale" => "en", "active_record_default_timezone" => "utc" },
      manifest["config"]
    )
  end

  def test_no_machine_specific_paths
    refute_includes IntrospectHelper.manifest_text, IntrospectHelper::APP
    refute_includes IntrospectHelper.manifest_text, Gem.dir
  end

  def test_cli_writes_the_same_manifest
    out = File.join(Dir.mktmpdir("rutile"), "manifest.json")
    stdout, stderr, status = Open3.capture3("ruby", EXE, "introspect", IntrospectHelper::APP, "--env", "test", "--out", out)
    assert status.success?, stderr
    assert_equal "wrote #{out}\n", stdout
    assert_equal IntrospectHelper.manifest_text, File.read(out)
  end

  def test_failed_run_raises_and_leaves_no_stale_manifest
    app = Dir.mktmpdir("fake-app")
    FileUtils.mkdir_p(File.join(app, "bin"))
    File.write(File.join(app, "bin/rails"), "#!/bin/sh\necho 'boot failed: no database' >&2\nexit 1\n")
    File.chmod(0o755, File.join(app, "bin/rails"))
    out = File.join(app, "manifest.json")
    File.write(out, "stale")

    error = assert_raises(Rutile::Introspect::Error) do
      Rutile::Introspect.run(app_dir: app, env: "test", out: out)
    end
    assert_match(/boot failed: no database/, error.message)
    refute File.exist?(out)
  end
end
```

Add to `test/cli_test.rb` (below `require "open3"` add `require "tmpdir"`; add this method inside `CliTest`):

```ruby
  def test_introspect_without_bin_rails_fails_cleanly
    dir = Dir.mktmpdir("not-an-app")
    _out, err, status = Open3.capture3("ruby", EXE, "introspect", dir)
    refute status.success?
    assert_equal "rutile introspect: no bin/rails in #{dir}\n", err
  end
```

- [ ] **Step 2: Make `rake test` prepare the database**

Replace `Rakefile`:

```ruby
require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.test_files = FileList["test/**/*_test.rb"]
end

# The introspection tests boot examples/blog, which needs its database.
task test: "example:db"

task default: %i[test example:test]
```

- [ ] **Step 3: Run the tests to see them fail**

Run: `bundle exec rake test`
Expected: FAIL with `NameError: uninitialized constant Rutile::Introspect`.

- [ ] **Step 4: Write the host side**

Create `lib/rutile/introspect.rb`:

```ruby
require "fileutils"
require "open3"
require_relative "unbundled"

module Rutile
  # Host side of `rutile introspect`: runs introspect/runner.rb inside the
  # target app with `bin/rails runner`. The runner writes the manifest.
  module Introspect
    class Error < StandardError; end

    RUNNER = File.expand_path("introspect/runner.rb", __dir__)

    module_function

    # vars: extra environment variables for the app process.
    def run(app_dir:, env:, out:, vars: {})
      rails = File.join(app_dir, "bin/rails")
      raise Error, "no bin/rails in #{app_dir}" unless File.exist?(rails)

      FileUtils.mkdir_p(File.dirname(out))
      FileUtils.rm_f(out)
      child_env = vars.merge("RAILS_ENV" => env, "RUTILE_MANIFEST_OUT" => out)
      _stdout, stderr, status = Rutile.unbundled do
        Open3.capture3(child_env, rails, "runner", RUNNER, chdir: app_dir)
      end
      unless status.success? && File.exist?(out)
        raise Error, "bin/rails runner failed in #{app_dir}:\n#{stderr.lines.last(20).join}"
      end

      out
    end
  end
end
```

Create `lib/rutile/cli.rb`:

```ruby
require "optparse"

module Rutile
  # Parses arguments and dispatches. Each command's work lives in its own module.
  class CLI
    USAGE = <<~TEXT
      usage: rutile --version
             rutile introspect [APP_DIR] [--env ENV] [--out FILE]
    TEXT

    def initialize(argv, out: $stdout, err: $stderr)
      @argv = argv.dup
      @out = out
      @err = err
    end

    def run
      case @argv.shift
      when "--version", "-v"
        @out.puts "rutile #{VERSION}"
        0
      when "introspect"
        introspect
      else
        usage
      end
    end

    private

    def introspect
      options = { env: "development" }
      OptionParser.new do |parser|
        parser.on("--env ENV") { options[:env] = _1 }
        parser.on("--out FILE") { options[:out] = _1 }
      end.parse!(@argv)
      app_dir = File.expand_path(@argv.shift || ".")
      out = File.expand_path(options[:out] || File.join(app_dir, "tmp/rutile/manifest.json"))
      Introspect.run(app_dir: app_dir, env: options[:env], out: out)
      @out.puts "wrote #{out}"
      0
    rescue OptionParser::ParseError
      usage
    rescue Introspect::Error => e
      @err.puts "rutile introspect: #{e.message}"
      1
    end

    def usage
      @err.puts USAGE
      1
    end
  end
end
```

Replace `lib/rutile.rb`:

```ruby
require "prism"
require_relative "rutile/version"
require_relative "rutile/introspect"
require_relative "rutile/cli"

# Rutile compiles Rails apps written in a strict subset of Ruby to Rust.
# See docs/design.md; `rutile introspect` is the only command so far.
module Rutile
end
```

Replace `exe/rutile`:

```ruby
#!/usr/bin/env ruby
require_relative "../lib/rutile"

exit Rutile::CLI.new(ARGV).run
```

- [ ] **Step 5: Write the in-app side**

Create `lib/rutile/introspect/source.rb`:

```ruby
module Rutile
  module Introspect
    # File locations in the manifest, relative to the app root. Anything
    # outside the app (Rails, gems, Ruby) gets no location, so a manifest
    # doesn't depend on where gems happen to be installed.
    module Source
      module_function

      def location(path = nil, line = nil)
        root = "#{Rails.root}/"
        return nil unless path&.start_with?(root)

        { "path" => path.delete_prefix(root), "line" => line }
      end

      def const_location(name)
        location(*Object.const_source_location(name))
      end

      def method_location(owner, name)
        location(*owner.instance_method(name).source_location)
      rescue NameError
        nil
      end

      def app_defined?(klass)
        return false unless klass.name

        const_location(klass.name)&.fetch("path")&.start_with?("app/") || false
      end
    end
  end
end
```

Create `lib/rutile/introspect/config.rb`:

```ruby
module Rutile
  module Introspect
    # Application settings that change what a request observes.
    module Config
      module_function

      def extract(app)
        {
          "api_only" => app.config.api_only,
          "time_zone" => app.config.time_zone,
          "default_locale" => I18n.default_locale.to_s,
          "active_record_default_timezone" => ActiveRecord.default_timezone.to_s
        }
      end
    end
  end
end
```

Create `lib/rutile/introspect/manifest.rb`:

```ruby
require_relative "source"
require_relative "config"

module Rutile
  module Introspect
    # Assembles the manifest. Every section comes out in a fixed order so two
    # runs over the same app produce byte-identical JSON.
    module Manifest
      VERSION = 1

      module_function

      def build(app)
        {
          "manifest_version" => VERSION,
          "rails_version" => Rails.version,
          "ruby_version" => RUBY_VERSION,
          "config" => Config.extract(app)
        }
      end
    end
  end
end
```

Create `lib/rutile/introspect/runner.rb`:

```ruby
# Loaded by `bin/rails runner` inside the target app (see Rutile::Introspect.run).
# It may use only Ruby's standard library and Rails: the app's Gemfile doesn't
# include Rutile, and nothing outside this directory is loaded here.
require "json"
require_relative "manifest"

Rails.application.eager_load!
manifest = Rutile::Introspect::Manifest.build(Rails.application)
File.write(ENV.fetch("RUTILE_MANIFEST_OUT"), JSON.pretty_generate(manifest) + "\n")
```

- [ ] **Step 6: Run the tests**

Run: `bundle exec rake test`
Expected: `8 runs, ... 0 failures, 0 errors, 0 skips`

Run: `bundle exec exe/rutile introspect examples/blog --env test && head -5 examples/blog/tmp/rutile/manifest.json`
Expected: `wrote .../examples/blog/tmp/rutile/manifest.json`, then `{`, `"manifest_version": 1,` and the Rails and Ruby versions. The file sits under the app's ignored `tmp/`, so `git status --short` shows nothing new in `examples/blog`.

- [ ] **Step 7: Document the format**

Create `docs/manifest.md`:

````markdown
# Manifest format

`rutile introspect` boots a Rails app and writes what Rails built at load time to `tmp/rutile/manifest.json` (or `--out`). The compiler reads this file instead of trying to understand Rails' metaprogramming. `manifest_version` goes up whenever the format changes.

```bash
rutile introspect path/to/app --env development
```

Conventions:

- Lists keep a fixed order: definition order where Rails has one, sorted by name otherwise. Two runs over the same app give identical files.
- Locations look like `{"path": "app/models/post.rb", "line": 12}`, relative to the app root. Anything defined outside the app (Rails, gems) has `null` instead, so the file carries no machine-specific paths.
- Symbols become strings. Option values JSON can't express get a one-key tag: `{"regexp": "...", "options": 0}`, `{"range": [1, 5], "exclude_end": false}`, `{"class": "User"}`, `{"proc": <location or null>}`, `{"object": "SomeClass"}`.

## Top level

| Key | Meaning |
|---|---|
| `manifest_version` | format version, currently 1 |
| `rails_version`, `ruby_version` | what the app booted with |
| `config` | the settings below |

## `config`

| Key | Example | Meaning |
|---|---|---|
| `api_only` | `true` | `config.api_only` |
| `time_zone` | `"UTC"` | `config.time_zone`, what `Time.current` uses |
| `default_locale` | `"en"` | `I18n.default_locale`, which picks validation messages |
| `active_record_default_timezone` | `"utc"` | how Active Record stores times |
````

- [ ] **Step 8: Commit**

```bash
git add lib exe Rakefile test docs/manifest.md
git commit -m "rutile introspect: run inside the app, write manifest header and config" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Tables and columns

**Files:**
- Create: `lib/rutile/introspect/tables.rb`
- Modify: `lib/rutile/introspect/manifest.rb`
- Create: `test/introspect/tables_test.rb`
- Modify: `test/introspect_helper.rb`, `docs/manifest.md`

**Interfaces:**
- Consumes: `IntrospectHelper#manifest` (Task 4).
- Produces: manifest key `"tables"`; `Rutile::Introspect::Tables.extract -> Array<Hash>`; helper methods `table(name)` and `column(table, name)`.

- [ ] **Step 1: Add the helpers and the failing test**

Add inside `module IntrospectHelper` in `test/introspect_helper.rb`, after `def manifest`:

```ruby
  def table(name)
    manifest.fetch("tables").find { _1["name"] == name } || flunk("no table #{name}")
  end

  def column(table, name)
    table.fetch("columns").find { _1["name"] == name } || flunk("no column #{name}")
  end
```

Create `test/introspect/tables_test.rb`:

```ruby
require_relative "../introspect_helper"

class TablesTest < Minitest::Test
  include IntrospectHelper

  def test_lists_app_tables_only
    assert_equal %w[comments posts users], manifest["tables"].map { _1["name"] }
  end

  def test_column_details
    posts = table("posts")
    assert_equal "id", posts["primary_key"]
    assert_equal(
      { "name" => "status", "type" => "integer", "sql_type" => "integer", "null" => false,
        "default" => "0", "default_function" => nil, "limit" => 4, "precision" => nil, "scale" => nil },
      column(posts, "status")
    )
    published_at = column(posts, "published_at")
    assert_equal ["datetime", true, 6], published_at.values_at("type", "null", "precision")
  end

  def test_columns_keep_database_order
    assert_equal %w[id user_id title body status published_at comments_count created_at updated_at],
                 table("posts")["columns"].map { _1["name"] }
  end
end
```

- [ ] **Step 2: Run to see it fail**

Run: `bundle exec rake test`
Expected: FAIL in `TablesTest` with `NoMethodError: undefined method 'map' for nil` (no `tables` key yet).

- [ ] **Step 3: Implement**

Create `lib/rutile/introspect/tables.rb`:

```ruby
module Rutile
  module Introspect
    # Tables and columns from the live database connection, which is what
    # Active Record itself uses (schema.rb can lag behind).
    module Tables
      INTERNAL = %w[ar_internal_metadata schema_migrations].freeze

      module_function

      def extract
        ActiveRecord::Base.with_connection do |connection|
          (connection.tables - INTERNAL).sort.map do |name|
            {
              "name" => name,
              "primary_key" => connection.primary_key(name),
              "columns" => connection.columns(name).map { column(_1) }
            }
          end
        end
      end

      def column(column)
        {
          "name" => column.name,
          "type" => column.type.to_s,
          "sql_type" => column.sql_type,
          "null" => column.null,
          "default" => column.default,
          "default_function" => column.default_function,
          "limit" => column.limit,
          "precision" => column.precision,
          "scale" => column.scale
        }
      end
    end
  end
end
```

In `lib/rutile/introspect/manifest.rb`, add `require_relative "tables"` after `require_relative "config"`, and add this entry after `"config" => Config.extract(app)` (add a comma to the config line):

```ruby
          "tables" => Tables.extract
```

- [ ] **Step 4: Run the tests**

Run: `bundle exec rake test`
Expected: `11 runs, ... 0 failures, 0 errors, 0 skips`

- [ ] **Step 5: Document**

Append to `docs/manifest.md`:

````markdown

## `tables`

Every table except Rails' own bookkeeping (`schema_migrations`, `ar_internal_metadata`), sorted by name, read from the live connection.

```json
{
  "name": "posts",
  "primary_key": "id",
  "columns": [
    {"name": "status", "type": "integer", "sql_type": "integer", "null": false,
     "default": "0", "default_function": null, "limit": 4, "precision": null, "scale": null}
  ]
}
```

Columns keep database order. `type` is Active Record's type name; `default` is the database default as a string, `default_function` is set instead when the default is an expression such as `nextval(...)`.
````

- [ ] **Step 6: Commit**

```bash
git add lib/rutile/introspect test docs/manifest.md
git commit -m "Manifest: tables and columns" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Models — associations, validators, enums

**Files:**
- Create: `lib/rutile/introspect/serialize.rb`, `lib/rutile/introspect/models.rb`
- Modify: `lib/rutile/introspect/manifest.rb`, `test/introspect_helper.rb`, `docs/manifest.md`
- Create: `test/introspect/serialize_test.rb`, `test/introspect/models_test.rb`

**Interfaces:**
- Consumes: `Source` (Task 4).
- Produces: manifest key `"models"`; `Rutile::Introspect::Serialize.value(v) -> JSON-safe value`; `Rutile::Introspect::Models.app_models -> Array<Class>` (used by Task 7's guard), `Models.extract`, `Models.describe(model) -> Hash` (Task 7 adds keys); helper `model(name)`.

- [ ] **Step 1: Write the failing Serialize unit test**

`serialize.rb` only touches Rails in its Proc branch, so it loads without Rails. Create `test/introspect/serialize_test.rb`:

```ruby
require "minitest/autorun"
require_relative "../../lib/rutile/introspect/serialize"

class SerializeTest < Minitest::Test
  S = Rutile::Introspect::Serialize

  def test_json_native_values_pass_through
    assert_equal [1, 2.5, "a", true, false, nil], S.value([1, 2.5, "a", true, false, nil])
  end

  def test_symbols_become_strings
    assert_equal "destroy", S.value(:destroy)
  end

  def test_hash_keys_become_sorted_strings
    assert_equal [["a", 1], ["b", "x"]], S.value({ b: :x, a: 1 }).to_a
  end

  def test_regexp_range_and_class_are_tagged
    assert_equal({ "regexp" => "\\A\\d+\\z", "options" => 0 }, S.value(/\A\d+\z/))
    assert_equal({ "range" => [1, 5], "exclude_end" => true }, S.value(1...5))
    assert_equal({ "class" => "String" }, S.value(String))
  end

  def test_infinite_floats_become_strings
    assert_equal "Infinity", S.value(Float::INFINITY)
  end

  def test_unknown_objects_keep_their_class_name
    assert_equal({ "object" => "Object" }, S.value(Object.new))
  end
end
```

- [ ] **Step 2: Write the failing models test**

Add inside `module IntrospectHelper`:

```ruby
  def model(name)
    manifest.fetch("models").find { _1["name"] == name } || flunk("no model #{name}")
  end
```

Create `test/introspect/models_test.rb`:

```ruby
require "uri"
require_relative "../introspect_helper"

class ModelsTest < Minitest::Test
  include IntrospectHelper

  def test_lists_app_models_only
    assert_equal %w[Comment Post User], manifest["models"].map { _1["name"] }
  end

  def test_table_and_source
    post = model("Post")
    assert_equal "posts", post["table_name"]
    assert_equal({ "path" => "app/models/post.rb", "line" => 1 }, post["source"])
  end

  def test_attribute_types
    attributes = model("Post")["attributes"]
    assert_equal %w[body comments_count created_at id published_at status title updated_at user_id], attributes.keys
    assert_equal %w[integer datetime string], attributes.values_at("status", "published_at", "title")
  end

  def test_associations_in_definition_order
    assert_equal(
      [
        { "macro" => "belongs_to", "name" => "user", "class_name" => "User", "foreign_key" => "user_id", "options" => {} },
        { "macro" => "has_many", "name" => "comments", "class_name" => "Comment", "foreign_key" => "post_id",
          "options" => { "dependent" => "destroy" } }
      ],
      model("Post")["associations"]
    )
  end

  def test_validators_keep_their_options
    title = model("Post")["validators"].select { _1["attributes"] == ["title"] }
    assert_equal %w[presence length], title.map { _1["kind"] }
    assert_equal({ "maximum" => 200 }, title.last["options"])
  end

  def test_regexp_options_are_tagged
    format = model("User")["validators"].find { _1["kind"] == "format" }
    assert_equal ["email"], format["attributes"]
    assert_equal URI::MailTo::EMAIL_REGEXP.source, format["options"]["with"]["regexp"]
  end

  def test_belongs_to_adds_a_required_validator_with_a_framework_condition
    user = model("Post")["validators"].find { _1["attributes"] == ["user"] }
    assert_equal "presence", user["kind"]
    assert_equal({ "if" => { "proc" => nil }, "message" => "required" }, user["options"])
  end

  def test_enums
    assert_equal({ "status" => { "draft" => 0, "published" => 1 } }, model("Post")["enums"])
    assert_equal({}, model("User")["enums"])
  end

  def test_enum_validate_adds_an_inclusion_validator
    status = model("Post")["validators"].find { _1["attributes"] == ["status"] }
    assert_equal ["inclusion", { "in" => %w[draft published] }], status.values_at("kind", "options")
  end
end
```

- [ ] **Step 3: Run to see them fail**

Run: `bundle exec rake test`
Expected: FAIL with `LoadError` for `serialize` in `SerializeTest`, and `NoMethodError ... for nil` in `ModelsTest`.

- [ ] **Step 4: Implement Serialize**

Create `lib/rutile/introspect/serialize.rb`:

```ruby
module Rutile
  module Introspect
    # Turns option values (association and validator options) into JSON.
    # Values JSON can't express get a one-key tag so nothing is lost silently.
    module Serialize
      module_function

      def value(v)
        case v
        when Float then v.finite? ? v : v.to_s
        when nil, true, false, Integer, String then v
        when Symbol then v.to_s
        when Array then v.map { value(_1) }
        when Hash then v.to_h { |key, val| [key.to_s, value(val)] }.sort.to_h
        when Regexp then { "regexp" => v.source, "options" => v.options }
        when Range then { "range" => [value(v.begin), value(v.end)], "exclude_end" => v.exclude_end? }
        when Module then { "class" => v.name }
        when Proc then { "proc" => Source.location(*v.source_location) }
        else { "object" => v.class.name }
        end
      end
    end
  end
end
```

- [ ] **Step 5: Implement Models**

Create `lib/rutile/introspect/models.rb`:

```ruby
require_relative "source"
require_relative "serialize"

module Rutile
  module Introspect
    # Every non-abstract Active Record model defined under app/.
    module Models
      module_function

      def app_models
        ActiveRecord::Base.descendants
          .reject(&:abstract_class?)
          .select { Source.app_defined?(_1) }
          .sort_by(&:name)
      end

      def extract
        app_models.map { describe(_1) }
      end

      def describe(model)
        {
          "name" => model.name,
          "table_name" => model.table_name,
          "source" => Source.const_location(model.name),
          # Every attribute Active Record knows, including `attribute` declarations with no column.
          "attributes" => model.attribute_types.sort.to_h { |name, type| [name, type.type.to_s] },
          "associations" => model.reflect_on_all_associations.map { association(_1) },
          "validators" => model.validators.map { validator(_1) },
          "enums" => model.defined_enums.sort.to_h { |name, mapping| [name, mapping.to_h] }
        }
      end

      def association(reflection)
        {
          "macro" => reflection.macro.to_s,
          "name" => reflection.name.to_s,
          "class_name" => reflection.class_name,
          "foreign_key" => reflection.foreign_key.to_s,
          "options" => Serialize.value(reflection.options)
        }
      end

      def validator(validator)
        {
          "kind" => validator.kind.to_s,
          "class" => validator.class.name,
          "attributes" => validator.respond_to?(:attributes) ? validator.attributes.map(&:to_s) : [],
          "options" => Serialize.value(validator.options)
        }
      end
    end
  end
end
```

In `lib/rutile/introspect/manifest.rb`, add `require_relative "models"` after `require_relative "tables"`, and add after the `"tables"` entry (comma on the previous line):

```ruby
          "models" => Models.extract
```

- [ ] **Step 6: Run the tests**

Run: `bundle exec rake test`
Expected: `26 runs, ... 0 failures, 0 errors, 0 skips`

- [ ] **Step 7: Document**

Append to `docs/manifest.md`:

````markdown

## `models`

Every non-abstract Active Record model whose class is defined under `app/`, sorted by name.

```json
{
  "name": "Post",
  "table_name": "posts",
  "source": {"path": "app/models/post.rb", "line": 1},
  "attributes": {"id": "integer", "status": "integer", "title": "string", "...": "..."},
  "associations": [
    {"macro": "has_many", "name": "comments", "class_name": "Comment",
     "foreign_key": "post_id", "options": {"dependent": "destroy"}}
  ],
  "validators": [
    {"kind": "length", "class": "ActiveRecord::Validations::LengthValidator",
     "attributes": ["title"], "options": {"maximum": 200}}
  ],
  "enums": {"status": {"draft": 0, "published": 1}}
}
```

`attributes` maps every attribute Active Record knows to its type name, sorted, including ones declared with `attribute` that have no column. Enum attributes report their stored type (`integer`).

Validators include the ones Rails adds for you: `belongs_to` adds a `presence` validator with `message: "required"` and a framework condition (`{"proc": null}`), and `enum ..., validate: true` adds an `inclusion` validator.
````

- [ ] **Step 8: Commit**

```bash
git add lib/rutile/introspect test docs/manifest.md
git commit -m "Manifest: models with associations, validators and enums" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: Models — callbacks and scopes

**Files:**
- Create: `lib/rutile/introspect/callbacks.rb`, `lib/rutile/introspect/scope_recorder.rb`
- Modify: `lib/rutile/introspect/models.rb`, `lib/rutile/introspect/runner.rb`, `test/introspect/models_test.rb`, `docs/manifest.md`

**Interfaces:**
- Consumes: `Source`, `Models.app_models`, `Models.describe`, `Introspect.run(..., vars:)`.
- Produces:
  - `Rutile::Introspect::Callbacks.entry(callback, owner) -> {"kind", "filter", "if", "unless"}` and `Callbacks.filter(value, owner) -> Hash` (both reused by Task 9 for controller filters and rescue handlers)
  - `Rutile::Introspect::ScopeRecorder.install!`, `.scopes_for(model) -> Array<Hash>`
  - model keys `"callbacks"` and `"scopes"`

- [ ] **Step 1: Write the failing tests**

Add to `test/introspect/models_test.rb`, inside the class:

```ruby
  def app_callbacks(name)
    model(name)["callbacks"].flat_map do |event, entries|
      entries.select { _1["filter"]["origin"] == "app" }.map { [event, _1] }
    end
  end

  def test_app_callbacks_keep_their_conditions
    assert_equal(
      [["save", {
        "kind" => "before",
        "filter" => { "method" => "stamp_published_at", "origin" => "app",
                      "source" => { "path" => "app/models/post.rb", "line" => 16 } },
        "if" => [{ "method" => "published?", "origin" => "framework", "source" => nil }],
        "unless" => []
      }]],
      app_callbacks("Post")
    )
  end

  def test_block_callbacks_point_at_their_source
    assert_equal(
      [["validation", {
        "kind" => "before",
        "filter" => { "proc" => { "path" => "app/models/user.rb", "line" => 5 }, "origin" => "app" },
        "if" => [], "unless" => []
      }]],
      app_callbacks("User")
    )
  end

  def test_after_create_callback
    assert_equal [["create", "after", "bump_post_counter"]],
                 app_callbacks("Comment").map { |event, entry| [event, entry["kind"], entry["filter"]["method"]] }
  end

  def test_framework_callbacks_are_kept_and_marked
    destroy = model("Post")["callbacks"].fetch("destroy")
    assert destroy.any? { _1["filter"]["origin"] == "framework" }, "dependent: :destroy adds a framework before_destroy"
  end

  def test_validators_are_not_repeated_as_callbacks
    validate = model("Post")["callbacks"].fetch("validate", [])
    assert validate.none? { _1["filter"]["object"].to_s.end_with?("Validator") }
  end

  def test_scopes_include_app_and_enum_scopes
    scopes = model("Post")["scopes"]
    assert_equal %w[draft not_draft not_published published recent visible], scopes.map { _1["name"] }
    assert_equal({ "name" => "recent", "origin" => "app", "source" => { "path" => "app/models/post.rb", "line" => 9 } },
                 scopes.find { _1["name"] == "recent" })
    assert_equal "framework", scopes.find { _1["name"] == "draft" }["origin"]
  end

  def test_eager_loaded_app_is_refused
    out = File.join(Dir.mktmpdir("rutile"), "manifest.json")
    error = assert_raises(Rutile::Introspect::Error) do
      Rutile::Introspect.run(app_dir: IntrospectHelper::APP, env: "test", out: out, vars: { "CI" => "1" })
    end
    assert_match(/loaded before introspection started/, error.message)
  end
```

- [ ] **Step 2: Run to see them fail**

Run: `bundle exec rake test`
Expected: FAIL. `NoMethodError: undefined method 'flat_map' for nil` in the callback tests, nil scopes, and `test_eager_loaded_app_is_refused` fails with `Rutile::Introspect::Error expected but nothing was raised`.

- [ ] **Step 3: Implement Callbacks**

Create `lib/rutile/introspect/callbacks.rb`:

```ruby
require_relative "source"

module Rutile
  module Introspect
    # Callback chains (model callbacks, controller filters) as data. Rails keeps
    # :if/:unless and before_action's only:/except: in instance variables with
    # no public reader, so this file is tied to Rails 8.1.
    module Callbacks
      module_function

      def entry(callback, owner)
        {
          "kind" => callback.kind.to_s,
          "filter" => filter(callback.filter, owner),
          "if" => conditions(callback.instance_variable_get(:@if), owner),
          "unless" => conditions(callback.instance_variable_get(:@unless), owner)
        }
      end

      def filter(value, owner)
        case value
        when Symbol
          source = Source.method_location(owner, value)
          { "method" => value.to_s, "origin" => method_origin(owner, value, source), "source" => source }
        when Proc
          source = Source.location(*value.source_location)
          { "proc" => source, "origin" => source ? "app" : "framework" }
        else
          { "object" => value.class.name, "origin" => Source.app_defined?(value.class) ? "app" : "framework" }
        end
      end

      # before_action's only:/except: become ActionFilter conditions; only:
      # lands in "if", except: in "unless".
      def conditions(list, owner)
        list.map do |condition|
          if condition.is_a?(AbstractController::Callbacks::ActionFilter)
            { "actions" => condition.instance_variable_get(:@actions).to_a.sort }
          else
            filter(condition, owner)
          end
        end
      end

      def method_origin(owner, name, source)
        return "missing" unless owner.method_defined?(name) || owner.private_method_defined?(name)

        source ? "app" : "framework"
      end
    end
  end
end
```

- [ ] **Step 4: Implement ScopeRecorder**

Create `lib/rutile/introspect/scope_recorder.rb`:

```ruby
require_relative "source"

module Rutile
  module Introspect
    # Rails keeps no list of a model's scopes, so record `scope` calls while
    # the models load. install! has to run before eager loading.
    module ScopeRecorder
      @scopes = Hash.new { |hash, key| hash[key] = [] }

      def self.install!
        ActiveRecord::Base.singleton_class.prepend(Hook)
      end

      def self.record(model, name, body)
        location = body.source_location if body.respond_to?(:source_location)
        source = Source.location(*location)
        @scopes[model.name] << { "name" => name.to_s, "origin" => source ? "app" : "framework", "source" => source }
      end

      def self.scopes_for(model)
        @scopes[model.name].sort_by { _1["name"] }
      end

      module Hook
        def scope(name, body, &block)
          ScopeRecorder.record(self, name, body)
          super
        end
      end
    end
  end
end
```

- [ ] **Step 5: Wire them into Models and the runner**

In `lib/rutile/introspect/models.rb`, add after `require_relative "serialize"`:

```ruby
require_relative "callbacks"
require_relative "scope_recorder"
```

In `Models.describe`, add after the `"enums"` entry (comma on the previous line):

```ruby
          "callbacks" => callbacks(model),
          "scopes" => ScopeRecorder.scopes_for(model)
```

Add this method to `Models`, after `validator`:

```ruby
      # Validators already appear under "validators"; Rails also registers
      # each one as a validate callback, so those are skipped here.
      def callbacks(model)
        model.__callbacks.sort.each_with_object({}) do |(event, chain), out|
          entries = chain.reject { _1.filter.is_a?(ActiveModel::Validator) }.map { Callbacks.entry(_1, model) }
          out[event.to_s] = entries unless entries.empty?
        end
      end
```

Replace `lib/rutile/introspect/runner.rb`:

```ruby
# Loaded by `bin/rails runner` inside the target app (see Rutile::Introspect.run).
# It may use only Ruby's standard library and Rails: the app's Gemfile doesn't
# include Rutile, and nothing outside this directory is loaded here.
require "json"
require_relative "manifest"

if Rutile::Introspect::Models.app_models.any?
  abort "rutile: app models were loaded before introspection started, so their scopes can't be recorded. " \
        "Run introspection with config.eager_load off (development, or test without CI set)."
end

Rutile::Introspect::ScopeRecorder.install!
Rails.application.eager_load!
manifest = Rutile::Introspect::Manifest.build(Rails.application)
File.write(ENV.fetch("RUTILE_MANIFEST_OUT"), JSON.pretty_generate(manifest) + "\n")
```

- [ ] **Step 6: Run the tests**

Run: `bundle exec rake test`
Expected: `33 runs, ... 0 failures, 0 errors, 0 skips`

- [ ] **Step 7: Document**

Append to `docs/manifest.md`:

````markdown

### `callbacks`

Keyed by event (`save`, `create`, `validation`, `destroy`, ...), each a list in chain order. Framework callbacks stay in, because they are behavior the runtime must reproduce (autosave, `dependent: :destroy`).

```json
"save": [
  {"kind": "before",
   "filter": {"method": "stamp_published_at", "origin": "app",
              "source": {"path": "app/models/post.rb", "line": 16}},
   "if": [{"method": "published?", "origin": "framework", "source": null}],
   "unless": []}
]
```

A filter is a method (`{"method", "origin", "source"}`), a block (`{"proc", "origin"}`) or an object (`{"object", "origin"}`). `origin` is `app` for code inside the app, `framework` for Rails or gems, `missing` for a method name nobody defines. Validator objects are left out here; they're listed under `validators`.

### `scopes`

Sorted by name. `origin: "framework"` marks scopes Rails generated, such as `published` and `not_published` from an enum.

```json
{"name": "recent", "origin": "app", "source": {"path": "app/models/post.rb", "line": 9}}
```

Scopes are recorded while models load, so introspection refuses to run on an app that loaded its models during boot (`config.eager_load = true`, which the test environment turns on when `CI` is set). Use the development environment, or test without `CI`.
````

- [ ] **Step 8: Commit**

```bash
git add lib/rutile/introspect test docs/manifest.md
git commit -m "Manifest: model callbacks and scopes" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: Routes

**Files:**
- Create: `lib/rutile/introspect/routes.rb`, `test/introspect/routes_test.rb`
- Modify: `lib/rutile/introspect/manifest.rb`, `docs/manifest.md`

**Interfaces:**
- Consumes: `Serialize.value` (Task 6).
- Produces: manifest key `"routes"`; `Rutile::Introspect::Routes.extract(app) -> Array<Hash>`.

- [ ] **Step 1: Write the failing test**

Create `test/introspect/routes_test.rb`:

```ruby
require_relative "../introspect_helper"

class RoutesTest < Minitest::Test
  include IntrospectHelper

  def route(verb, path)
    manifest.fetch("routes").find { _1["verb"] == verb && _1["path"] == path } || flunk("no route #{verb} #{path}")
  end

  def test_resource_routes
    assert_equal(
      { "verb" => "GET", "path" => "/posts(.:format)", "controller" => "posts", "action" => "index",
        "name" => "posts", "requirements" => {} },
      route("GET", "/posts(.:format)")
    )
    assert_equal ["posts", "update", nil], route("PATCH", "/posts/:id(.:format)").values_at("controller", "action", "name")
  end

  def test_nested_routes
    assert_equal ["comments", "create"],
                 route("POST", "/posts/:post_id/comments(.:format)").values_at("controller", "action")
  end

  def test_api_resources_have_no_new_or_edit
    refute manifest["routes"].any? { %w[new edit].include?(_1["action"]) }
  end

  def test_health_check
    assert_equal ["rails/health", "show", "rails_health_check"],
                 route("GET", "/up(.:format)").values_at("controller", "action", "name")
  end
end
```

- [ ] **Step 2: Run to see it fail**

Run: `bundle exec rake test`
Expected: FAIL in `RoutesTest` with `KeyError: key not found: "routes"`.

- [ ] **Step 3: Implement**

Create `lib/rutile/introspect/routes.rb`:

```ruby
require_relative "serialize"

module Rutile
  module Introspect
    # The app's routes in match order.
    module Routes
      module_function

      def extract(app)
        app.routes.routes.map do |route|
          {
            "verb" => route.verb,
            "path" => route.path.spec.to_s,
            "controller" => route.defaults[:controller],
            "action" => route.defaults[:action],
            "name" => route.name,
            "requirements" => Serialize.value(route.requirements.except(:controller, :action))
          }
        end
      end
    end
  end
end
```

In `lib/rutile/introspect/manifest.rb`, add `require_relative "routes"` after `require_relative "models"`, and add after the `"models"` entry (comma on the previous line):

```ruby
          "routes" => Routes.extract(app)
```

- [ ] **Step 4: Run the tests**

Run: `bundle exec rake test`
Expected: `37 runs, ... 0 failures, 0 errors, 0 skips`

- [ ] **Step 5: Document**

Append to `docs/manifest.md`:

````markdown

## `routes`

In match order (the order Rails tries them). `name` is set only on the first route for a path, as in `bin/rails routes`. `requirements` holds constraints such as `{"id": {"regexp": "\\d+", "options": 0}}`.

```json
{"verb": "GET", "path": "/posts(.:format)", "controller": "posts", "action": "index",
 "name": "posts", "requirements": {}}
```
````

- [ ] **Step 6: Commit**

```bash
git add lib/rutile/introspect test docs/manifest.md
git commit -m "Manifest: routes" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 9: Controllers, and the README status

**Files:**
- Create: `lib/rutile/introspect/controllers.rb`, `test/introspect/controllers_test.rb`
- Modify: `lib/rutile/introspect/manifest.rb`, `test/introspect_helper.rb`, `docs/manifest.md`, `README.md`

**Interfaces:**
- Consumes: `Source`, `Callbacks.entry`, `Callbacks.filter` (Task 7).
- Produces: manifest key `"controllers"`; `Rutile::Introspect::Controllers.extract -> Array<Hash>`; helper `controller(name)`.

- [ ] **Step 1: Write the failing test**

Add inside `module IntrospectHelper`:

```ruby
  def controller(name)
    manifest.fetch("controllers").find { _1["name"] == name } || flunk("no controller #{name}")
  end
```

Create `test/introspect/controllers_test.rb`:

```ruby
require_relative "../introspect_helper"

class ControllersTest < Minitest::Test
  include IntrospectHelper

  def test_lists_app_controllers_only
    assert_equal %w[ApplicationController CommentsController PostsController UsersController],
                 manifest["controllers"].map { _1["name"] }
  end

  def test_superclass_source_and_actions
    posts = controller("PostsController")
    assert_equal "ApplicationController", posts["superclass"]
    assert_equal({ "path" => "app/controllers/posts_controller.rb", "line" => 1 }, posts["source"])
    assert_equal %w[create destroy index show update], posts["actions"]
    assert_equal [], controller("ApplicationController")["actions"]
  end

  def test_before_action_only_becomes_an_actions_condition
    assert_equal(
      [{
        "kind" => "before",
        "filter" => { "method" => "set_post", "origin" => "app",
                      "source" => { "path" => "app/controllers/posts_controller.rb", "line" => 37 } },
        "if" => [{ "actions" => %w[destroy show update] }],
        "unless" => []
      }],
      controller("PostsController")["filters"]
    )
  end

  def test_rescue_handlers_are_inherited
    assert_equal(
      [{ "exception" => "ActiveRecord::RecordNotFound",
         "handler" => { "method" => "not_found", "origin" => "app",
                        "source" => { "path" => "app/controllers/application_controller.rb", "line" => 6 } } }],
      controller("PostsController")["rescue_handlers"]
    )
  end

  def test_param_wrapping
    assert_equal(
      { "format" => ["json"], "name" => "post",
        "include" => %w[body comments_count created_at id published_at status title updated_at user_id],
        "exclude" => nil },
      controller("PostsController")["param_wrapping"]
    )
  end
end
```

- [ ] **Step 2: Run to see it fail**

Run: `bundle exec rake test`
Expected: FAIL in `ControllersTest` with `KeyError: key not found: "controllers"`.

- [ ] **Step 3: Implement**

Create `lib/rutile/introspect/controllers.rb`:

```ruby
require_relative "source"
require_relative "callbacks"

module Rutile
  module Introspect
    # Controllers defined under app/, with filter chains, rescue_from
    # handlers and JSON parameter wrapping.
    module Controllers
      module_function

      def extract
        ActionController::Metal.descendants
          .select { Source.app_defined?(_1) }
          .sort_by(&:name)
          .map { describe(_1) }
      end

      def describe(controller)
        {
          "name" => controller.name,
          "superclass" => controller.superclass.name,
          "source" => Source.const_location(controller.name),
          "actions" => controller.action_methods.to_a.sort,
          "filters" => controller._process_action_callbacks.map { Callbacks.entry(_1, controller) },
          "rescue_handlers" => controller.rescue_handlers.map { |exception, handler| rescue_handler(exception, handler, controller) },
          "param_wrapping" => param_wrapping(controller)
        }
      end

      def rescue_handler(exception, handler, controller)
        { "exception" => exception, "handler" => Callbacks.filter(handler, controller) }
      end

      # Rails wraps top-level JSON keys that match the model's attributes
      # under the controller's name, so {"title": ...} reaches the action as
      # params[:post][:title]. The runtime has to do the same.
      def param_wrapping(controller)
        options = controller._wrapper_options
        return nil if options.format.empty?

        {
          "format" => options.format.map(&:to_s),
          "name" => options.name,
          "include" => options.include&.sort,
          "exclude" => options.exclude&.sort
        }
      end
    end
  end
end
```

In `lib/rutile/introspect/manifest.rb`, add `require_relative "controllers"` after `require_relative "routes"`, and add after the `"routes"` entry (comma on the previous line):

```ruby
          "controllers" => Controllers.extract
```

- [ ] **Step 4: Run everything**

Run: `bundle exec rake`
Expected: Rutile's suite `42 runs, ... 0 failures, 0 errors, 0 skips`, then the example app's `27 runs, ... 0 failures, 0 errors, 0 skips`.

Run: `wc -l lib/rutile/*.rb lib/rutile/introspect/*.rb | sort -n | tail -3`
Expected: no file over 200 lines.

- [ ] **Step 5: Document**

Append to `docs/manifest.md`:

````markdown

## `controllers`

Every controller class defined under `app/`, sorted by name.

```json
{
  "name": "PostsController",
  "superclass": "ApplicationController",
  "source": {"path": "app/controllers/posts_controller.rb", "line": 1},
  "actions": ["create", "destroy", "index", "show", "update"],
  "filters": [
    {"kind": "before",
     "filter": {"method": "set_post", "origin": "app", "source": {"path": "...", "line": 37}},
     "if": [{"actions": ["destroy", "show", "update"]}], "unless": []}
  ],
  "rescue_handlers": [
    {"exception": "ActiveRecord::RecordNotFound",
     "handler": {"method": "not_found", "origin": "app", "source": {"path": "...", "line": 6}}}
  ],
  "param_wrapping": {"format": ["json"], "name": "post",
                     "include": ["body", "title", "..."], "exclude": null}
}
```

`filters` uses the callback format above. `before_action only: [...]` shows up as `{"actions": [...]}` in `if`, and `except:` as the same in `unless`. `rescue_handlers` includes inherited ones, in the order Rails stores them (Rails checks them last to first). `param_wrapping` is `null` when wrapping is off.
````

In `README.md`, replace the line starting with `**Status:**` with:

```markdown
**Status:** design stage, started 2026-09-25. `rutile introspect` works (format in [docs/manifest.md](docs/manifest.md)); `check`, `build` and `verify` don't exist yet. The PoC target app is [examples/blog](examples/blog).
```

- [ ] **Step 6: Commit**

```bash
git add lib/rutile/introspect test docs/manifest.md README.md
git commit -m "Manifest: controllers with filters, rescue handlers and param wrapping" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```
