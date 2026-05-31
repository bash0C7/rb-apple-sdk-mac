# frozen_string_literal: true

# swift_mkmf.rb + swift_version_check.rb are vendored into this ext dir so the
# extension builds without swift_gem on the load path (rubygems' ext builder
# runs a plain `ruby extconf.rb` outside bundler's load-path setup).
require_relative "swift_mkmf"

SwiftGem::Mkmf.create_swift_makefile(
  "apple_sdk_mac/apple_sdk_mac_runtime",
  package: "AppleSDKMacRuntime",
  source_dir: __dir__
)
