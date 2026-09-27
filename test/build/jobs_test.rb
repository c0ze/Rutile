require_relative "../build_helper"
require_relative "../store_helper"

# Active Job on Sidekiq: a job class becomes src/jobs/<job>.rs, and
# perform_later pushes what Sidekiq's adapter would.
class JobsTest < Minitest::Test
  include BuildHelper
  include StoreHelper

  def action(ruby, app = store)
    controller = Rutile::Build::ApplicationControllerFile.new(app)
    translator = Rutile::Build::Translator.new(app, "snippet.rb", Rutile::Build::Uses.new, env: :controller, controller:)
    translator.body(Prism.parse(ruby).value.statements, :response).first.join("\n")
  end

  def refused(message, ruby)
    error = assert_raises(Rutile::Build::Unsupported) { action(ruby) }
    assert_equal "snippet.rb:#{message} isn't supported yet", error.message
  end

  def job_file(app = store) = Rutile::Build::JobFile.new(app, app.job("RestockJob"))

  def edited_job(ruby)
    scratch_app({ "app/jobs/restock_job.rb" => ->(source) { source.sub(/  #: .*\z/m, "#{ruby}end\n") } },
                manifest: StoreHelper.manifest, from: StoreHelper::APP)
  end

  def test_the_store_has_one_job_on_sidekiq
    assert_equal "sidekiq", StoreHelper.manifest.dig("jobs", "adapter")
    assert_equal "store", StoreHelper.manifest.dig("jobs", "app")
    job = store.job("RestockJob")
    assert_equal ["default", false, "app/jobs/restock_job.rb"], [job["queue"], job["after_commit"], job.dig("perform", "path")]
  end

  # `run` is perform as written; `perform` takes the serialized arguments.
  def test_a_job_file
    rust = job_file.to_rust
    assert_rust_includes rust, 'pub const RESTOCK_JOB: Job = Job { class: "RestockJob", queue: "default" };'
    assert_rust_includes rust, "pub fn run(ctx: &mut Ctx, product: Handle<Product>, amount: i64) -> Result<()> {\n" \
                               "Product::restock_bang(ctx, product, amount)?;\nOk(())\n}"
    assert_rust_includes rust, "let product = jobs::record_at::<Product>(ctx, arguments, 0)?;"
    assert_rust_includes rust, "let amount = jobs::scalar_at::<i64>(arguments, 1)?;"
    assert_rust_includes rust, "run(ctx, product, amount)"
  end

  def test_perform_later_enqueues_the_arguments_active_job_serializes
    rust = action("RestockJob.perform_later(Product.find(params[:id]), 2)\nhead :accepted")
    assert_rust_includes rust, "crate::jobs::restock_job::RESTOCK_JOB.perform_later(&crate::jobs::APP, vec![" \
                               "rustonrails::jobs::record_argument::<Product>(&req.ctx, &crate::jobs::APP, Some(product))?, " \
                               "{ let argument: i64 = 2; Json::from(argument) }])?;"
  end

  # Rails enqueues nil for a record; the job fails on it when it runs.
  def test_perform_later_passes_a_nilable_record
    rust = action("RestockJob.perform_later(Product.order(:id).first, 1)\nhead :accepted")
    assert_rust_includes rust, "rustonrails::jobs::record_argument::<Product>(&req.ctx, &crate::jobs::APP, product)?"
  end

  def test_perform_now_runs_the_job_here
    rust = action("RestockJob.perform_now(Product.find(params[:id]), 2)\nhead :ok")
    assert_rust_includes rust, "crate::jobs::restock_job::run(&mut req.ctx, product, 2)?;"
  end

  def test_what_a_call_cant_pass
    refused "1: passing str to RestockJob.perform_later's amount (int)", 'RestockJob.perform_later(Product.find(1), "2")'
    refused "1: RestockJob.perform_later with 1 argument for 2", "RestockJob.perform_later(Product.find(1))"
    refused "1: passing Product or nil to RestockJob.perform_now's product (Product)",
            "RestockJob.perform_now(Product.order(:id).first, 1)"
  end

  def test_jobs_that_are_refused
    { "  def perform(product, amount) = product.restock!(amount)\n" =>
        "a perform with parameters and no rbs-inline signature",
      "  #: (Product, ?Integer) -> void\n  def perform(product, amount = 1) = product.restock!(amount)\n" =>
        "a perform with optional or keyword parameters",
      "  #: (Time) -> void\n  def perform(at) = nil\n" => "RestockJob's at, time, as a job argument" }.each do |ruby, message|
      error = assert_raises(Rutile::Build::Unsupported) { job_file(edited_job(ruby)).to_rust }
      assert_includes error.message, message
    end
  end

  # With enqueue_after_transaction_commit a job waits for the commit; this
  # side enqueues at once, so it's refused.
  def test_a_job_enqueued_after_commit_is_refused
    manifest = JSON.parse(JSON.generate(StoreHelper.manifest))
    manifest.dig("jobs", "classes").each { _1["after_commit"] = true }
    app = Rutile::Build::App.new(StoreHelper::APP, manifest, diagnostics: Rutile::Build::Diagnostics.new)
    error = assert_raises(Rutile::Build::Unsupported) { job_file(app).to_rust }
    assert_equal "app/jobs/restock_job.rb: RestockJob with enqueue_after_transaction_commit isn't supported yet", error.message
  end

  def test_a_job_on_another_adapter_is_refused
    manifest = JSON.parse(JSON.generate(StoreHelper.manifest))
    manifest["jobs"]["adapter"] = "async"
    app = Rutile::Build::App.new(StoreHelper::APP, manifest, diagnostics: Rutile::Build::Diagnostics.new)
    error = assert_raises(Rutile::Build::Unsupported) { action("RestockJob.perform_later(Product.find(1), 1)\nhead :ok", app) }
    assert_equal "snippet.rb:1: RestockJob on the async queue adapter; jobs run on Sidekiq's isn't supported yet", error.message
  end

  # ApplicationJob's declarations apply to every job, so they're checked too.
  def test_application_job_is_checked
    assert_equal ["app/jobs/application_job.rb"], store.job("RestockJob")["ancestors"]
    body = ->(source) { source.sub("class ApplicationJob < ActiveJob::Base\n", "class ApplicationJob < ActiveJob::Base\n  discard_on ActiveJob::DeserializationError\n") }
    app = scratch_app({ "app/jobs/application_job.rb" => body }, manifest: StoreHelper.manifest, from: StoreHelper::APP)
    error = assert_raises(Rutile::Build::Unsupported) { job_file(app).to_rust }
    assert_equal "app/jobs/application_job.rb:2: discard_on in a class body isn't supported yet", error.message
  end

  # A perform inherited from ApplicationJob still runs the job's own
  # callbacks in Rails, so the job's own file is checked too.
  def test_the_jobs_own_file_is_checked_when_perform_is_inherited
    manifest = JSON.parse(JSON.generate(StoreHelper.manifest))
    manifest.dig("jobs", "classes").find { _1["name"] == "RestockJob" }["perform"]["path"] = "app/jobs/application_job.rb"
    app = scratch_app({
      "app/jobs/application_job.rb" => ->(source) { source.sub(/\nend\s*\z/, "\n  def perform = nil\nend\n") },
      "app/jobs/restock_job.rb" => ->(source) { source.sub(/  #: .*\z/m, "  before_perform :stop\nend\n") }
    }, manifest:, from: StoreHelper::APP)
    error = assert_raises(Rutile::Build::Unsupported) { job_file(app).to_rust }
    assert_match(%r{\Aapp/jobs/restock_job.rb:\d+: before_perform in a class body isn't supported yet\z}, error.message)
  end

  # nil and an Integer past i32 go into the payload as the types the
  # signature declares, not as whatever Rust would infer for a literal.
  def test_a_nil_record_argument_names_its_model
    uses = Rutile::Build::Uses.new
    controller = Rutile::Build::ApplicationControllerFile.new(store)
    translator = Rutile::Build::Translator.new(store, "snippet.rb", uses, env: :controller, controller:)
    rust = translator.body(Prism.parse("RestockJob.perform_later(nil, 2)\nhead :accepted").value.statements, :response).first.join("\n")
    assert_rust_includes rust, "rustonrails::jobs::record_argument::<Product>(&req.ctx, &crate::jobs::APP, None)?"
    assert_includes uses.lines("crate::models"), "Product"
  end

  def test_arguments_keep_their_declared_types
    app = edited_job("  #: (String?, Integer) -> void\n  def perform(label, count) = nil\n")
    rust = action("RestockJob.perform_later(nil, 3_000_000_000)\nhead :accepted", app)
    assert_rust_includes rust, "{ let argument: Option<String> = None; Json::from(argument) }"
    assert_rust_includes rust, "{ let argument: i64 = 3000000000; Json::from(argument) }"
  end

  def test_jobs_that_depend_on_their_environment_or_namespace_are_refused
    manifest = JSON.parse(JSON.generate(StoreHelper.manifest))
    manifest.dig("jobs", "classes").first["queue_prefix"] = "store_production"
    app = Rutile::Build::App.new(StoreHelper::APP, manifest)
    error = assert_raises(Rutile::Build::Unsupported) { job_file(app).to_rust }
    assert_match(/queue_name_prefix \(store_production\), which Rails usually sets per environment/, error.message)
    manifest.dig("jobs", "classes").first.merge!("queue_prefix" => nil, "name" => "Admin::RestockJob")
    error = assert_raises(Rutile::Build::Unsupported) { Rutile::Build::JobFile.new(app, app.jobs.first).to_rust }
    assert_equal "app/jobs/restock_job.rb: the namespaced job Admin::RestockJob isn't supported yet", error.message
  end

  # Ruby checks the argument count before perform runs.
  def test_arity_is_checked
    assert_rust_includes job_file.to_rust, "pub fn perform(ctx: &mut Ctx, arguments: &[Json]) -> Result<()> {\njobs::arity(arguments, 2)?;"
  end
end
