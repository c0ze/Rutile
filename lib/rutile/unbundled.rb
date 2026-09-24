module Rutile
  # Runs the block without Bundler's environment, so commands started inside
  # it use the target app's Gemfile instead of Rutile's.
  def self.unbundled(&block)
    defined?(Bundler) ? Bundler.with_unbundled_env(&block) : yield
  end
end
