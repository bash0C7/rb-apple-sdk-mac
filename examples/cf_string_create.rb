# frozen_string_literal: true
require "apple_sdk_mac"
require "fiddle"

ENCODING_UTF8 = 0x08000100

Apple.discover(framework: :CoreFoundation, symbol: :CFStringCreateWithCString)

Apple.discover(
  framework: :CoreFoundation, symbol: :CFStringGetLength,
  params: [{ kind: :cftype_ref, type: "CFString" }],
  return_kind: :int
)
Apple.discover(
  framework: :CoreFoundation, symbol: :CFStringGetCString,
  params: [
    { kind: :cftype_ref, type: "CFString" },
    :void_ptr_nilable,
    { kind: :int, type: "CFIndex" },
    { kind: :int, type: "CFStringEncoding" }
  ],
  return_kind: :bool
)

boxed_cfstring = Apple::CoreFoundation.CFStringCreateWithCString(
  nil, "hello", ENCODING_UTF8
)
raise "expected non-zero CF auto-ARC box pointer" unless boxed_cfstring.is_a?(Integer) && boxed_cfstring > 0
puts "boxed_cfstring=#{boxed_cfstring}"

length = Apple::CoreFoundation.CFStringGetLength(boxed_cfstring)
puts "length=#{length}"

buf_size = 64
buffer = Fiddle::Pointer.malloc(buf_size, Fiddle::RUBY_FREE)
ok = Apple::CoreFoundation.CFStringGetCString(
  boxed_cfstring, buffer.to_i, buf_size, ENCODING_UTF8
)
raise "CFStringGetCString failed" unless ok && ok != 0

read_back = buffer.to_s
puts "read_back=#{read_back}"
raise "expected hello, got #{read_back.inspect}" unless read_back == "hello"

puts "auto-ARC OK — runtime BoxedCFType owns release"
