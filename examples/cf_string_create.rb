# frozen_string_literal: true
# T50 — CFStringCreateWithCString → CFStringGetLength → CFStringGetCString の
# 完全 round-trip。spec §3.9。
#
# 1. CFStringCreateWithCString が CF Create-rule で +1 retained。
#    runtime ARC pillar が BoxedCFType に wrap し、Ruby は box pointer
#    Integer を持つ。手動 CFRelease は呼ばない (Ruby GC で box deinit が
#    CFRelease をする)。
# 2. CFStringGetLength(box) は cftype_ref Marshaller の
#    runtime_arc_unbox_cftype unwrap で内部 CFString pointer に戻して call。
#    "hello" の長さ 5 を取得。
# 3. CFStringGetCString(box, buffer, size, encoding) で Ruby 側で確保した
#    char buffer に書き込んで Ruby String "hello" に戻す。
#
# Usage:
#   RUBY_BOX=1 bundle exec ruby examples/cf_string_create.rb
require "apple_sdk_mac"
require "fiddle"

ENCODING_UTF8 = 0x08000100  # kCFStringEncodingUTF8

# CFStringCreateWithCString は KB の分類だけで OK (CF Create-rule 検出)。
Apple.discover(framework: :CoreFoundation, symbol: :CFStringCreateWithCString)

# T50 — KB は CFStringRef を `string` に、CFStringGetCString の buffer を
# `is_out_param=true` の string out に分類する。round-trip では params /
# return_kind を override して正しい kind 配列を渡す。
# cftype_ref param は :type ヒントで Swift bridged 型 (CFString) を指定。
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
