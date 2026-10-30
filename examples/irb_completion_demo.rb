# frozen_string_literal: true
require "apple_sdk_mac"
require "apple_sdk_mac/irb"
require "irb"

AppleSDKMac::IRB.install!
provider = AppleSDKMac::IRB.apple_provider
completor = AppleSDKMac::IRB::Completor.new(provider: provider, base: nil)

out = completor.completion_candidates("", "Apple::", "", bind: binding)
raise "Phase 1: no frameworks listed" if out.empty?
puts "Phase 1: Apple:: TAB → #{out.first(5).inspect} ... (#{out.size} total)"

out = completor.completion_candidates("", "Apple::Foundation::U", "", bind: binding)
raise "Phase 2: U prefix returned no candidates" if out.empty?
puts "Phase 2: Apple::Foundation::U TAB → #{out.first(5).inspect} ... (#{out.size} total)"

out = completor.completion_candidates("", "Apple::Foundation::URL.", "", bind: binding)
raise "Phase 3: URL. returned no candidates" if out.empty?
puts "Phase 3: Apple::Foundation::URL. TAB → #{out.first(5).inspect} ... (#{out.size} total)"

puts "irb_completion_demo OK"
