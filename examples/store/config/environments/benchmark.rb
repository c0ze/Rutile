# Production settings, minus what a local benchmark can't use: plain HTTP
# instead of forced SSL, and no per-request logging (the Rust server has none).
require_relative "production"

Rails.application.configure do
  config.assume_ssl = false
  config.force_ssl = false
  config.log_level = :warn
  # YJIT is on, as Rails 7.2+ turns it on; RAILS_YJIT=0 measures the interpreter.
  config.yjit = ENV.fetch("RAILS_YJIT", "1") == "1"
end
