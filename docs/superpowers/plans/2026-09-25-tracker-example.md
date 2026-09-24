# Tracker example Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A second example app, `examples/tracker`, written the way an ordinary Rails 8 API is written (not shaped for Rutile), with integration tests passing on Rails, and `docs/gaps.md`: what `rutile check` reports on it, grouped and ranked, which is the work list for the plans after this one.

**Architecture:** The app copies the blog's skeleton (Gemfile, config, bin) and has its own models, controllers, routes, migrations, fixtures and integration tests. The example rake tasks take `EXAMPLE=tracker` (default `blog`) so `example:db`, `example:test` and `example:check` run against either app; `build`, `verify` and `benchmark` stay blog-only. Nothing in Rutile's compiler changes, except fixes for any crash `rutile check` hits on the new app (a crash is a bug; a finding is data).

**Tech Stack:** Rails 8.1.4 API app on Ruby 3.4.9, PostgreSQL 16 (the local cluster), minitest.

**Spec:** `docs/design.md` (Goal, Proof of concept: the next milestone after the blog is "a classic Rails app"), and `rutile check` as plan 6 built it.

## Global Constraints

- The tracker is idiomatic Rails: it uses what a Rails developer reaches for without thinking about Rutile (`has_many :through`, `class_name:`, `optional: true`, several enums, `normalizes`, `has_secure_token`, numericality and scoped uniqueness validations, SQL-string scopes, a `date` column, an auth filter reading a header, `skip_before_action`, member routes, shallow nesting, pagination, `create!`/`update!` with `rescue_from RecordInvalid`, model methods called from controllers, a block over records in a controller).
- Its integration tests pass on Rails: `bundle exec rake example:test EXAMPLE=tracker`.
- The blog is untouched; `bundle exec rake example:test` (blog) stays 30/30, Rutile's suite and `example:check` (blog) stay as they are.
- `rutile check` must not crash on the tracker; every finding is data for `docs/gaps.md`.
- `docs/gaps.md` quotes the real report (counts per kind), ranks the gaps by how many findings each unlocks and how common the construct is in Rails apps, and says what each would need in Rutile and RustOnRails.

## Review Focus

1. **The app is honest.** It isn't bent to avoid Rutile's gaps, and it isn't padded with exotic Rails either; every feature is one a typical API has.
2. **Tests prove the behavior verify will later compare.** Status codes and JSON bodies for success, validation failure (422), missing records and other users' records (404), and missing tokens (401).
3. **The gap list matches the report.** Counts in `docs/gaps.md` equal the `rutile check` output committed alongside it.
4. **EXAMPLE plumbing doesn't leak.** `EXAMPLE=tracker` never points `build`/`verify`/`benchmark` at the tracker; they refuse instead.

---

### Task 1: The tracker app, passing on Rails

**Files:**
- Create: `examples/tracker/` (skeleton copied from `examples/blog`: `.gitignore`, `.ruby-version`, `Gemfile`, `Gemfile.lock`, `Rakefile`, `config.ru`, `bin/rails`, `bin/rake`, `bin/setup`, `config/{application,boot,environment,database,puma}.rb|yml`, `config/environments/{development,test,production}.rb`, `config/initializers/filter_parameter_logging.rb`, `config/locales/en.yml`, `log/.keep`, `tmp/.keep`)
- Create: `examples/tracker/db/migrate/*.rb`, `db/schema.rb` (generated), `app/models/*.rb`, `app/controllers/*.rb`, `config/routes.rb`, `test/test_helper.rb`, `test/fixtures/*.yml`, `test/integration/*_test.rb`
- Modify: `rakelib/example.rake` (`EXAMPLE`), `Rakefile` (default runs both apps' tests)

**Interfaces:**
- Produces: `EXAMPLE_APP` from `ENV.fetch("EXAMPLE", "blog")`; `rake example:db|test|check EXAMPLE=tracker`; `build`/`verify`/`benchmark` abort unless the example is `blog`.

- [ ] **Step 1: Skeleton and EXAMPLE plumbing**

Copy the listed skeleton files from `examples/blog` to `examples/tracker`. In the copies: `module Blog` → `module Tracker` (`config/application.rb`); `blog_development`/`blog_test`/`blog_production` → `tracker_*` and `BLOG_` → `TRACKER_` (`config/database.yml`, which keeps no `benchmark:` entry).

In `rakelib/example.rake`: `EXAMPLE = ENV.fetch("EXAMPLE", "blog")`, `EXAMPLE_APP = File.expand_path("../examples/#{EXAMPLE}", __dir__)`; at the top of `build`, `verify` (and `benchmark` in `rakelib/benchmark.rake`): `abort "only the blog has a Rust crate (EXAMPLE=#{EXAMPLE})" unless EXAMPLE == "blog"`. In `Rakefile`: `task default: %i[test example:test tracker:test]` with `namespace(:tracker) { task(:test) { sh({ "EXAMPLE" => "tracker" }, "bundle exec rake example:test") } }`.

- [ ] **Step 2: Schema**

Migrations (timestamps `20260925080001`…`04`):

```ruby
class CreateUsers < ActiveRecord::Migration[8.1]
  def change
    create_table :users do |t|
      t.string :name, null: false
      t.string :email, null: false
      t.string :api_token, null: false
      t.timestamps
    end
    add_index :users, :email, unique: true
    add_index :users, :api_token, unique: true
  end
end

class CreateProjects < ActiveRecord::Migration[8.1]
  def change
    create_table :projects do |t|
      t.string :name, null: false
      t.references :owner, null: false, foreign_key: { to_table: :users }
      t.datetime :archived_at
      t.timestamps
    end
    add_index :projects, %i[owner_id name], unique: true
  end
end

class CreateMemberships < ActiveRecord::Migration[8.1]
  def change
    create_table :memberships do |t|
      t.references :user, null: false, foreign_key: true
      t.references :project, null: false, foreign_key: true
      t.integer :role, null: false, default: 0
      t.timestamps
    end
    add_index :memberships, %i[user_id project_id], unique: true
  end
end

class CreateTasks < ActiveRecord::Migration[8.1]
  def change
    create_table :tasks do |t|
      t.references :project, null: false, foreign_key: true
      t.references :assignee, foreign_key: { to_table: :users }
      t.string :title, null: false
      t.text :notes
      t.integer :status, null: false, default: 0
      t.integer :priority, null: false, default: 1
      t.integer :estimate
      t.date :due_on
      t.datetime :completed_at
      t.timestamps
    end
  end
end
```

Run: `bundle exec rake example:db EXAMPLE=tracker && git -C examples/tracker status --short db/schema.rb`
Expected: `db/schema.rb` created with the four tables.

- [ ] **Step 3: Models**

```ruby
class ApplicationRecord < ActiveRecord::Base
  primary_abstract_class
end
```

```ruby
class User < ApplicationRecord
  has_many :memberships, dependent: :destroy
  has_many :projects, through: :memberships
  has_many :owned_projects, class_name: "Project", foreign_key: :owner_id, dependent: :destroy, inverse_of: :owner
  has_many :assigned_tasks, class_name: "Task", foreign_key: :assignee_id, dependent: :nullify, inverse_of: :assignee

  has_secure_token :api_token
  normalizes :email, with: ->(email) { email.strip.downcase }

  validates :name, presence: true
  validates :email, presence: true, uniqueness: true
end
```

```ruby
class Project < ApplicationRecord
  belongs_to :owner, class_name: "User"
  has_many :memberships, dependent: :destroy
  has_many :members, through: :memberships, source: :user
  has_many :tasks, dependent: :destroy

  validates :name, presence: true, length: { maximum: 100 }, uniqueness: { scope: :owner_id }

  scope :active, -> { where(archived_at: nil) }

  after_create :add_owner_as_admin

  def archived? = archived_at.present?

  def archive!
    update!(archived_at: Time.current)
  end

  private

  def add_owner_as_admin
    memberships.create!(user: owner, role: :admin)
  end
end
```

```ruby
class Membership < ApplicationRecord
  belongs_to :user
  belongs_to :project

  enum :role, { member: 0, admin: 1 }, validate: true

  validates :user_id, uniqueness: { scope: :project_id }
end
```

```ruby
class Task < ApplicationRecord
  belongs_to :project
  belongs_to :assignee, class_name: "User", optional: true

  enum :status, { todo: 0, doing: 1, done: 2 }, validate: true
  enum :priority, { low: 0, normal: 1, high: 2 }, validate: true

  validates :title, presence: true, length: { maximum: 200 }
  validates :estimate, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validate :assignee_is_a_member

  scope :unfinished, -> { where.not(status: :done) }
  scope :search, ->(query) { where("title ILIKE ?", "%#{sanitize_sql_like(query)}%") }

  before_save :stamp_completion, if: :will_save_change_to_status?

  def overdue?
    due_on.present? && due_on < Date.current && !done?
  end

  private

  def assignee_is_a_member
    return if assignee.nil? || project.nil?

    errors.add(:assignee, "must be a member of the project") unless project.members.include?(assignee)
  end

  def stamp_completion
    self.completed_at = done? ? Time.current : nil
  end
end
```

- [ ] **Step 4: Controllers and routes**

```ruby
class ApplicationController < ActionController::API
  before_action :authenticate

  rescue_from ActiveRecord::RecordNotFound, with: :not_found
  rescue_from ActiveRecord::RecordInvalid, with: :invalid

  private

  attr_reader :current_user

  def authenticate
    @current_user = User.find_by(api_token: request.headers["X-Api-Token"].to_s)
    head :unauthorized unless @current_user
  end

  def not_found
    render json: { error: "not found" }, status: :not_found
  end

  def invalid(error)
    render json: error.record.errors, status: :unprocessable_content
  end

  def page
    [params.fetch(:page, 1).to_i, 1].max
  end
end
```

```ruby
class UsersController < ApplicationController
  skip_before_action :authenticate, only: :create

  def show
    render json: User.find(params[:id]).as_json(only: %i[id name email])
  end

  def create
    user = User.create!(user_params)
    render json: user.as_json(only: %i[id name email api_token]), status: :created
  end

  private

  def user_params
    params.expect(user: %i[name email])
  end
end
```

```ruby
class ProjectsController < ApplicationController
  PER_PAGE = 20

  before_action :set_project, only: %i[show update destroy archive]

  def index
    projects = current_user.projects.active.order(:name).limit(PER_PAGE).offset((page - 1) * PER_PAGE)
    render json: projects
  end

  def show
    render json: @project.as_json(include: { tasks: { only: %i[id title status] } })
  end

  def create
    project = current_user.owned_projects.create!(project_params)
    render json: project, status: :created
  end

  def update
    @project.update!(project_params)
    render json: @project
  end

  def destroy
    @project.destroy!
    head :no_content
  end

  def archive
    @project.archive!
    render json: @project
  end

  private

  def set_project
    @project = current_user.projects.find(params[:id])
  end

  def project_params
    params.expect(project: %i[name])
  end
end
```

```ruby
class TasksController < ApplicationController
  before_action :set_project, only: %i[index create]
  before_action :set_task, only: %i[show update destroy complete]

  def index
    tasks = @project.tasks.order(:due_on, :id)
    tasks = tasks.where(status: params[:status]) if params[:status].present?
    tasks = tasks.search(params[:q]) if params[:q].present?
    render json: tasks.map { |task| task.as_json.merge("overdue" => task.overdue?) }
  end

  def show
    render json: @task
  end

  def create
    task = @project.tasks.create!(task_params)
    render json: task, status: :created
  end

  def update
    @task.update!(task_params)
    render json: @task
  end

  def destroy
    @task.destroy!
    head :no_content
  end

  def complete
    @task.done!
    render json: @task
  end

  private

  def set_project
    @project = current_user.projects.find(params[:project_id])
  end

  def set_task
    @task = Task.joins(project: :memberships).where(memberships: { user_id: current_user.id }).find(params[:id])
  end

  def task_params
    params.expect(task: %i[title notes status priority estimate due_on assignee_id])
  end
end
```

```ruby
Rails.application.routes.draw do
  resources :users, only: %i[show create]
  resources :projects do
    post :archive, on: :member
    resources :tasks, shallow: true do
      patch :complete, on: :member
    end
  end

  get "up" => "rails/health#show", as: :rails_health_check
end
```

- [ ] **Step 5: Fixtures and integration tests**

`test/test_helper.rb` as the blog's (including the `RUTILE_TARGET` block), plus in `ActionDispatch::IntegrationTest`: `def auth(user) = { "X-Api-Token" => user.api_token }`.

Fixtures: users `alice`, `bob` (fixed `api_token`s `alice-token`, `bob-token`); projects `apollo` (owner alice), `hermes` (owner bob), `gemini` (owner alice, archived 2026-01-01); memberships alice–apollo admin, alice–gemini admin, bob–hermes admin, bob–apollo member; tasks on apollo: `launch` (todo, due 2026-01-10, assignee bob), `review` (doing, no due date), `ship` (done, completed); on hermes: `secret` (todo).

`test/integration/users_api_test.rb`:
- create without a token → 201 with id, name, normalized email, a 24-char api_token.
- create with a taken email → 422 `{"email" => ["has already been taken"]}`.
- show → 200, only id/name/email.
- show without a token → 401, empty body.

`test/integration/projects_api_test.rb`:
- index lists alice's active projects by name (apollo only; gemini archived; hermes not hers); `?page=2` → `[]`.
- create → 201; the creator is an admin member (`Membership.find_by(user:, project:).admin?`).
- create with a blank name → 422 `{"name" => ["can't be blank"]}`; a duplicate name for the same owner → 422 "has already been taken".
- show includes tasks with only id/title/status.
- show of bob's hermes as alice → 404 `{"error" => "not found"}`.
- update renames; archive sets `archived_at` and drops the project from index; destroy → 204 and its tasks are gone.

`test/integration/tasks_api_test.rb`:
- index orders by due date then id, each with `"overdue"` (launch true, review false, ship false).
- `?status=todo` filters; `?q=REV` finds review (case-insensitive).
- create → 201 with status todo, priority normal; `estimate: 0` → 422 "must be greater than 0"; assignee not a member → 422 `{"assignee" => ["must be a member of the project"]}`.
- complete → 200 status done and `completed_at` set; update back to doing clears `completed_at`.
- show of hermes' task as alice → 404; destroy → 204.

Run: `bundle exec rake example:test EXAMPLE=tracker 2>&1 | grep 'runs,'`
Expected: every test passing (about 25 runs), 0 failures, 0 errors.

- [ ] **Step 6: Commit**

```bash
git add examples/tracker rakelib Rakefile && git commit -m "examples/tracker: an ordinary Rails 8 API app, passing its integration tests"
```

### Task 2: What `rutile check` says about it

**Files:**
- Create: `docs/gaps.md`, `docs/tracker-check.txt` (the raw report)
- Modify: `lib/rutile/**` only if `rutile check` crashes on the tracker (each crash fixed test-first with a test that reproduces it from a scratch copy of the tracker)
- Modify: `README.md` (examples list), `docs/design.md` (Proof of concept: the tracker as the next milestone)

**Interfaces:**
- Consumes: `rake example:check EXAMPLE=tracker` (Task 1).
- Produces: `docs/gaps.md`.

- [ ] **Step 1: Run the check**

Run: `bundle exec rake example:check EXAMPLE=tracker > docs/tracker-check.txt 2>&1; tail -1 docs/tracker-check.txt`
Expected: a report ending in `N problems, M notes` with N well above 0, and no stack trace. A stack trace is a Rutile bug: reproduce it in a test under `test/check/` (scratch copy of `examples/tracker` with the one construct), fix it, rerun, and ledger the fix.

- [ ] **Step 2: Write `docs/gaps.md`**

Group every finding in `docs/tracker-check.txt` by what Rutile would need (for example: `has_many :through` and `class_name:` associations; `create!`/`update!` with attributes; model methods called from controllers; operators and literals such as `nil`, `==`, `<`, `&&`, `!`, arithmetic, string interpolation; `where.not` and SQL-string `where`; `date` columns; numericality and scoped uniqueness validators; `normalizes`, `has_secure_token`, `attr_reader`; `skip_before_action`; rescue handlers taking the exception; request headers; blocks over records; constants), with the count of findings in each group and the files involved. Rank the groups: first those that are both common in Rails apps and unlock many findings. For each, one or two sentences on the work in Rutile (translator, emitters, manifest) and in RustOnRails (runtime API), and whether it fits an existing pattern or needs a new one. Note separately what the report can't show (the verify proxy forwards only Content-Type/Accept/Accept-Encoding, so the `X-Api-Token` header needs forwarding before verify can run the tracker; runtime behavior differences only verify would catch).

- [ ] **Step 3: Docs and commit**

`README.md`: list both examples (blog: compiles and passes; tracker: the next target, see `docs/gaps.md`). `docs/design.md` "Proof of concept": one paragraph saying the blog milestone is met and the tracker is the next one.

Run: `bundle exec rake test 2>&1 | grep 'runs,' && bundle exec rake example:test 2>&1 | grep 'runs,'`
Expected: Rutile suite green; blog 30 runs green.

```bash
git add docs README.md lib test && git commit -m "The tracker through rutile check: the gap list for the next plans"
```

---

## Self-review

- Spec coverage: the design's next milestone after the blog is a classic Rails app compiled end to end; this plan builds the app and measures the distance, which is what the following plans need. Compiling it is out of scope here by design.
- Global Constraints map to Task 1 (idiomatic app, tests, blog untouched, EXAMPLE plumbing) and Task 2 (no crash, gap list from the real report).
- Review Focus tests: 1 → the constraint list of Rails features, visible in Task 1's code; 2 → Task 1 Step 5's test list; 3 → Task 2 commits the raw report next to `docs/gaps.md`; 4 → the `abort` guards in Step 1.
