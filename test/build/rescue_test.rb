require_relative "../build_helper"
require_relative "../tracker_helper"

# A rescue_from handler that takes the exception, as the tracker's
# `def invalid(error) = render json: error.record.errors, ...`.
class RescueTest < Minitest::Test
  include BuildHelper
  include TrackerHelper

  APPLICATION = "app/controllers/application_controller.rb"

  def application(app = tracker) = Rutile::Build::ApplicationControllerFile.new(app).to_rust

  # The tracker with ApplicationController#invalid's body replaced.
  def invalid_as(ruby, manifest: TrackerHelper.manifest)
    edit = ->(source) { source.sub(/  def invalid\(error\)\n.*?\n  end\n/m, "#{ruby.gsub(/^/, "  ")}\n") }
    scratch_app({ APPLICATION => edit }, manifest:, from: TrackerHelper::APP, diagnostics: Rutile::Build::Diagnostics.new)
  end

  def problems(app)
    application(app)
    app.diagnostics.problems
  end

  def test_the_handler_takes_the_record_invalid
    assert_rust_includes application, <<~RUST
      // app/controllers/application_controller.rb:20
      pub fn invalid(_req: &mut Request, error: RecordInvalid) -> Result<Response> {
          Ok(Response::json(status::UNPROCESSABLE_CONTENT, errors_json(&error.errors)))
      }
    RUST
    assert_match(/^use rustonrails::\{.*\bRecordInvalid\b.*\};$/, application)
  end

  def test_the_arm_passes_the_exception
    rust = Rutile::Build::ControllerFile.new(tracker, "UsersController").to_rust
    assert_rust_includes rust, <<~RUST
      fn rescue(&mut self, req: &mut Request, error: Error) -> Result<Response> {
          match error {
              // rescue_from ActiveRecord::RecordInvalid, with: :invalid
              Error::RecordInvalid(error) => application::invalid(req, error),
              // rescue_from ActiveRecord::RecordNotFound, with: :not_found
              Error::RecordNotFound { .. } => application::not_found(req),
              other => Err(other),
          }
      }
    RUST
  end

  def test_an_unused_exception
    assert_rust_includes application(invalid_as("def invalid(error) = head :unprocessable_content")),
                         "pub fn invalid(_req: &mut Request, _error: RecordInvalid) -> Result<Response> {"
  end

  # Ruby may read the local again, so it's a copy; so is its record, which
  # in Rust is the RecordInvalid that carries its errors.
  def test_the_exception_in_a_local
    ruby = "def invalid(error)\n  failed = error\n  record = error.record\n" \
           "  render json: { errors: record.errors, again: failed.record.errors }, status: 422\nend"
    assert_rust_includes application(invalid_as(ruby)),
                         "let failed = error.clone(); let record = error.clone(); Ok(Response::json(422, " \
                         'json!({ "errors": errors_json(&record.errors), "again": errors_json(&failed.errors) })))'
  end

  # In the controller's own handler, an instance variable can hold it.
  def test_the_exception_in_an_instance_variable
    manifest = JSON.parse(JSON.generate(TrackerHelper.manifest))
    users = manifest["controllers"].find { _1["name"] == "UsersController" }
    users["rescue_handlers"].last["handler"].merge!("method" => "rejected", "source" => { "path" => "app/controllers/users_controller.rb", "line" => 1 })
    handler = "  def rejected(error)\n    @invalid = error.record\n    render json: @invalid.errors, status: 422\n  end\n"
    add = ->(ruby) { ruby.sub(/^end\s*\z/, "\n  private\n\n#{handler}end\n") }
    app = scratch_app({ "app/controllers/users_controller.rb" => add }, manifest:, from: TrackerHelper::APP)
    rust = Rutile::Build::ControllerFile.new(app, "UsersController").to_rust
    assert_rust_includes rust, "invalid: Option<RecordInvalid>,"
    assert_match(/^use rustonrails::\{.*\bRecordInvalid\b.*\};$/, rust)
  end

  # The same method in this controller's own file is a method, not a function.
  def test_a_handler_in_the_controller_itself
    manifest = JSON.parse(JSON.generate(TrackerHelper.manifest))
    users = manifest["controllers"].find { _1["name"] == "UsersController" }
    users["rescue_handlers"].last["handler"].merge!("method" => "rejected", "source" => { "path" => "app/controllers/users_controller.rb", "line" => 1 })
    add = ->(ruby) { ruby.sub(/^end\s*\z/, "\n  private\n\n  def rejected(problem) = render json: problem.record.errors, status: 422\nend\n") }
    app = scratch_app({ "app/controllers/users_controller.rb" => add }, manifest:, from: TrackerHelper::APP)
    rust = Rutile::Build::ControllerFile.new(app, "UsersController").to_rust
    assert_rust_includes rust, "Error::RecordInvalid(error) => self.rejected(req, error),"
    assert_rust_includes rust, "fn rejected(&mut self, _req: &mut Request, problem: RecordInvalid) -> Result<Response> {\n" \
                               "Ok(Response::json(422, errors_json(&problem.errors)))"
  end

  def test_other_uses_of_the_exception_are_refused
    cases = {
      "def invalid(error) = render json: { error: error.message }" => "#{APPLICATION}:20: message on ActiveRecord::RecordInvalid",
      "def invalid(error) = render json: error.record" => "#{APPLICATION}:20: render json: the invalid record",
      "def invalid(error) = render json: error.record.errors.full_messages" => "#{APPLICATION}:20: full_messages on errors",
      "def invalid(error, status = 422) = head status" => "#{APPLICATION}:20: a rescue handler with parameters other than the exception"
    }
    cases.each do |ruby, message|
      assert_equal ["#{message} isn't supported yet"], problems(invalid_as(ruby)), ruby
    end
  end

  # RustOnRails' other errors carry nothing a handler could read yet.
  def test_a_handler_taking_another_exception_is_refused
    manifest = JSON.parse(JSON.generate(TrackerHelper.manifest))
    manifest["controllers"].each { |c| c["rescue_handlers"].first["handler"]["method"] = "invalid" if c["rescue_handlers"].any? }
    assert_includes problems(invalid_as("def invalid(error) = head 422", manifest:)),
                    "#{APPLICATION}:20: a rescue handler taking ActiveRecord::RecordNotFound isn't supported yet"
  end
end
