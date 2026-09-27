require "fileutils"
require_relative "introspect_helper"
require_relative "../lib/rutile/build"

# The example app as `rutile build` sees it, loaded once per test process.
module BuildHelper
  include IntrospectHelper

  # RustOnRails beside this repository, or wherever RUSTONRAILS_DIR says.
  RUNTIME = File.expand_path(ENV.fetch("RUSTONRAILS_DIR", File.expand_path("../../RustOnRails", __dir__)))

  def self.app
    @app ||= Rutile::Build::App.new(IntrospectHelper::APP, IntrospectHelper.manifest)
  end

  def app = BuildHelper.app

  # A copy of the manifest a test can break without touching the shared one.
  def app_with
    manifest = JSON.parse(IntrospectHelper.manifest_text)
    yield manifest
    Rutile::Build::App.new(IntrospectHelper::APP, manifest)
  end

  # Emitters leave layout to rustfmt, so compare without whitespace.
  def assert_rust_includes(actual, expected)
    assert_includes actual.gsub(/\s+/, ""), expected.gsub(/\s+/, ""), "in:\n#{actual}"
  end

  # A scratch copy of the example app with `edits` (path => ->(ruby) { ... })
  # applied, read with the example's manifest unless given another.
  def scratch_app(edits, diagnostics: nil, manifest: IntrospectHelper.manifest, from: IntrospectHelper::APP)
    root = Dir.mktmpdir
    FileUtils.cp_r(%w[app config].map { File.join(from, _1) }, root)
    edits.each { |path, change| File.write(File.join(root, path), change.(File.read(File.join(root, path)))) }
    Rutile::Build::App.new(root, manifest, diagnostics:)
  end
end
