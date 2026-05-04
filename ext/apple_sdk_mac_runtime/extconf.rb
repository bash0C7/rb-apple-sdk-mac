# frozen_string_literal: true

require "swift_gem/mkmf"

SwiftGem::Mkmf.create_swift_makefile(
  "apple_sdk_mac/apple_sdk_mac_runtime",
  package: "AppleSDKMacRuntime",
  source_dir: __dir__
)
