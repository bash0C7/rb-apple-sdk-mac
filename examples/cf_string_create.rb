# frozen_string_literal: true
# Phase 7 example: CFStringCreateWithCString — Core Foundation Create
# rule auto-ARC. Demonstrates that Phase 7's BoxedCFType / runtime ARC
# pillar releases CF objects when the Ruby reference goes out of scope:
# *no* explicit CFRelease is required by user code.
#
# Usage:
#   RUBY_BOX=1 bundle exec ruby examples/cf_string_create.rb
require "apple_sdk_mac"

# kCFStringEncodingUTF8 = 0x08000100 in Core Foundation.
ENCODING_UTF8 = 0x08000100

Apple.discover(
  framework: :CoreFoundation,
  symbol:    :CFStringCreateWithCString
)

# Calling with allocator=nil tells CF to use kCFAllocatorDefault. The
# return value is an opaque integer that wraps a +1-retained CFString
# inside a Swift BoxedCFType — Ruby GC drops the box, the runtime
# pillar releases the CF object, and the CFString is freed. User code
# never touches manual release primitives.
boxed_cfstring = Apple::CoreFoundation.CFStringCreateWithCString(
  nil, "hello, Apple SDK", ENCODING_UTF8
)

raise "expected non-zero CF auto-ARC box pointer" unless boxed_cfstring.is_a?(Integer) && boxed_cfstring > 0

puts "boxed_cfstring=#{boxed_cfstring}"
puts "auto-ARC OK — runtime BoxedCFType owns release"
