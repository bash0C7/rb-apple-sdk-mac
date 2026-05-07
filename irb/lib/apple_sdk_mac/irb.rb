# frozen_string_literal: true

# IRB autocomplete + doc preview + auto-discover prefetch for rb-apple-sdk-mac.
#
# Activated by:
#   require "apple_sdk_mac"      # main gem
#   require "apple_sdk_mac/irb"  # this sub-gem
#   AppleSDKMac::IRB.install!
#
# Logical sub-gem inside the rb-apple-sdk-mac repo, path-loaded via Gemfile.
# Never auto-required by lib/apple_sdk_mac.rb so non-IRB users do not pull
# in irb / reline / repl_type_completor / foundation_model_mac.
module AppleSDKMac
  module IRB
    # Implementation moves here in Step 1.2 (Task #44).
  end
end
