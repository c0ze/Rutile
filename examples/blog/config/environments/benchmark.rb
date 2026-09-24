# Production settings, minus what a local benchmark can't use: plain HTTP
# instead of forced SSL, and no per-request logging (the Rust server has none).
require_relative "production"

Rails.application.configure do
  config.assume_ssl = false
  config.force_ssl = false
  config.log_level = :warn
end
