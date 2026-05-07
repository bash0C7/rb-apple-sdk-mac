# frozen_string_literal: true
# IRB autocomplete demo. Reline session を直接 simulate せず、 install! 後に
# Reline.completion_proc を直接呼んで補完候補を、 Reline.dig_perfect_match_proc
# 経由で auto-discover trigger を確認する (release-quality demo: ヘッドレスで
# 動く)。
#
# Usage:
#   RUBY_BOX=1 bundle exec ruby examples/irb_completion_demo.rb
require "apple_sdk_mac"
require "apple_sdk_mac/irb_completion"
require "reline"

AppleSDKMac::IRBCompletion.install!

# Phase 1: framework 列挙
out = Reline.completion_proc.call("Apple::")
raise "Phase 1: no frameworks listed" if out.empty?
puts "Phase 1: Apple:: TAB → #{out.first(5).inspect} ... (#{out.size} total)"

# Phase 2: framework 内の class / type 列挙 (Swift import で ObjC prefix は
# strip されるため、 NSURL は URL、 NSData は Data として登録)
out = Reline.completion_proc.call("Apple::Foundation::U")
raise "Phase 2: U prefix returned no candidates" if out.empty?
puts "Phase 2: Apple::Foundation::U TAB → #{out.first(5).inspect} ... (#{out.size} total)"

# Phase 3: class の method 列挙 (URL struct の instance_method)
out = Reline.completion_proc.call("Apple::Foundation::URL.")
raise "Phase 3: URL. returned no candidates" if out.empty?
puts "Phase 3: Apple::Foundation::URL. TAB → #{out.first(5).inspect} ... (#{out.size} total)"

puts "irb_completion_demo OK"
