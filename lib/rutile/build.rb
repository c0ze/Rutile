require "prism"
require "set"

module Rutile
  # `rutile build`: the manifest plus the app's Ruby, written out as a Cargo
  # crate that runs on RustOnRails.
  module Build
    class Error < StandardError; end

    # A construct outside the subset Rutile compiles.
    class Unsupported < Error
      def self.at(path, node, what) = new("#{path}:#{node.location.start_line}: #{what} isn't supported yet")
    end
  end
end

require_relative "build/names"
require_relative "build/types"
require_relative "build/source"
require_relative "build/app"
require_relative "build/borrowing"
require_relative "build/model_calls"
require_relative "build/web_calls"
require_relative "build/translator"
require_relative "build/scopes_file"
require_relative "build/behavior"
require_relative "build/model_file"
require_relative "build/controller_file"
