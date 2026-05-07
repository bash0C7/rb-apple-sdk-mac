# frozen_string_literal: true
# T43 — ObjC class method dispatch via Apple.discover(class_method:).
# spec §3.4.1 + T42 emit_objc_class_method で deterministic に解決。
# Swift 6 の `+stringWithUTF8String:` は `NSString(utf8String:)` に rename
# されているため、emit は init-bridge form を出す。
#
# Apple::Foundation::NSString.stringWithUTF8String("hello") を呼ぶと、
# +1-retained NSString instance の raw pointer が Ruby Integer で返る。
# Ruby GC は pointer を保持するだけ; release は今後 BoxedNSObject が担う。
#
# Usage:
#   RUBY_BOX=1 bundle exec ruby examples/objc_classmethod.rb
require "apple_sdk_mac"

input = ENV["OBJC_INPUT"] || "rb-apple-sdk-mac"

Apple.discover(
  framework:    :Foundation,
  klass:        :NSString,
  class_method: "stringWithUTF8String:",
  params:       [:string],
  return_kind:  :opaque_ref
)
puts "discover OK"

result = Apple::Foundation::NSString.stringWithUTF8String(input)
# T52b — opaque_ref 戻り値は proxy instance に auto-wrap される。 raw pointer
# を取得するには __opaque_ref。
raw = result.respond_to?(:__opaque_ref) ? result.__opaque_ref : result
puts "result=#{raw}"
raise "expected non-zero NSString pointer" unless raw.is_a?(Integer) && raw > 0

puts "objc class method OK"
