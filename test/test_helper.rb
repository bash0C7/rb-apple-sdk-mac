# frozen_string_literal: true

# Set BEFORE require — runtime test helpers (AppleSDKMacRuntime::Test.*) only
# install when this env is set, so production gem builds don't ship test code.
ENV["RB_APPLE_SDK_MAC_RUNTIME_TEST"] ||= "1"

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "apple_sdk_mac"

require "test-unit"
