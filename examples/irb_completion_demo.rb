# frozen_string_literal: true
# IRB autocomplete headless demo. IRB::Context#build_completor を実際に
# 走らせる代わりに、 sub-gem の Completor を直接呼んで Apple SDK 補完経路
# (apple_root / module / class) が機能していることを検証。
#
# Usage:
#   RUBY_BOX=1 bundle exec ruby examples/irb_completion_demo.rb
require "apple_sdk_mac"
require "apple_sdk_mac/irb"
require "irb"

AppleSDKMac::IRB.install!
provider = AppleSDKMac::IRB.apple_provider
completor = AppleSDKMac::IRB::Completor.new(provider: provider, base: nil)

# Phase 1: framework 列挙
out = completor.completion_candidates("", "Apple::", "", bind: binding)
raise "Phase 1: no frameworks listed" if out.empty?
puts "Phase 1: Apple:: TAB → #{out.first(5).inspect} ... (#{out.size} total)"

# Phase 2: framework 内の class / type 列挙 (Swift import で ObjC prefix は
# strip されるため、 NSURL は URL、 NSData は Data として登録)
out = completor.completion_candidates("", "Apple::Foundation::U", "", bind: binding)
raise "Phase 2: U prefix returned no candidates" if out.empty?
puts "Phase 2: Apple::Foundation::U TAB → #{out.first(5).inspect} ... (#{out.size} total)"

# Phase 3: class の method 列挙 (URL struct の instance_method)
out = completor.completion_candidates("", "Apple::Foundation::URL.", "", bind: binding)
raise "Phase 3: URL. returned no candidates" if out.empty?
puts "Phase 3: Apple::Foundation::URL. TAB → #{out.first(5).inspect} ... (#{out.size} total)"

puts "irb_completion_demo OK"
