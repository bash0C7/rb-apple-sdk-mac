# frozen_string_literal: true

require "apple_sdk_mac"

Apple.discover(
  framework: :CoreFoundation,
  symbol: :CFStringCreateWithCString,
  params: [:opaque_ref, :cstring, :uint32],
  return_kind: :opaque_ref
)

ENCODING_UTF8 = 0x08000100
boxed = Apple::CoreFoundation.CFStringCreateWithCString(nil, "hello", ENCODING_UTF8)

raise "expected non-zero box pointer, got #{boxed.inspect}" unless boxed.is_a?(Integer) && boxed > 0

puts "discover_escape: CFStringCreateWithCString returned box=#{boxed}"

Apple.discover(
  framework:    :Foundation,
  klass:        :NSString,
  class_method: "stringWithUTF8String:",
  params:       [:string],
  return_kind:  :opaque_ref
)

ns_input = ENV["OBJC_INPUT"] || "rb-apple-sdk-mac"
ns_result = Apple::Foundation::NSString.stringWithUTF8String(ns_input)
ns_raw = ns_result.respond_to?(:__opaque_ref) ? ns_result.__opaque_ref : ns_result
raise "expected non-zero NSString pointer, got #{ns_raw.inspect}" unless ns_raw.is_a?(Integer) && ns_raw > 0

puts "discover_escape: NSString.stringWithUTF8String returned ptr=#{ns_raw}"
