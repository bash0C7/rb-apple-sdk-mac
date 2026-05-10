# frozen_string_literal: true
# Apple.discover は v1.2 で escape hatch 専用。 README L3 の「any public Apple
# framework API」 は AppleSDKMac.bootstrap! 経由で透過 dispatch する想定で、
# 通常コードに Apple.discover は現れない。
#
# このファイルは「KB に居らへん API / KB の分類を意図的に上書きしたい場合の
# 宣言形」 を 2 通り示す escape-hatch demo。
#
# 1. C function 直叩き — CoreFoundation `CFStringCreateWithCString` を
#    raw-ABI shape ([:opaque_ref, :cstring, :uint32] -> :opaque_ref) で。
# 2. ObjC class method — Foundation `+[NSString stringWithUTF8String:]` を
#    Apple.discover(class_method:) 経由で (Swift 6 は init bridge に rename)。
#
# Usage:
#   RUBY_BOX=1 bundle exec ruby examples/discover_escape.rb

require "apple_sdk_mac"

# ★ 重要: ここでは AppleSDKMac.bootstrap! を呼ばない。
# 単一 symbol を Apple.discover で宣言 → その場で呼べる、 という escape hatch
# としての最小ケースを示す。

# --- Case 1: C function 直叩き -------------------------------------------------

Apple.discover(
  framework: :CoreFoundation,
  symbol: :CFStringCreateWithCString,
  params: [:opaque_ref, :cstring, :uint32],
  return_kind: :opaque_ref
)

ENCODING_UTF8 = 0x08000100  # kCFStringEncodingUTF8
boxed = Apple::CoreFoundation.CFStringCreateWithCString(nil, "hello", ENCODING_UTF8)

raise "expected non-zero box pointer, got #{boxed.inspect}" unless boxed.is_a?(Integer) && boxed > 0

puts "discover_escape: CFStringCreateWithCString returned box=#{boxed}"

# --- Case 2: ObjC class method 経由 -------------------------------------------

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
