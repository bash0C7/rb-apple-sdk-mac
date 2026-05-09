# frozen_string_literal: true
# Apple.discover は v1.2 で escape hatch 専用。 README L3 の「any public Apple
# framework API」 は AppleSDKMac.bootstrap! 経由で透過 dispatch する想定で、
# 通常コードに Apple.discover は現れない。
#
# このファイルは spec § 1.2 principle 2 / principle 5 の例示として、
# 「KB に居らへん API / KB の分類を意図的に上書きしたい場合の宣言形」 を
# 1 回だけ叩いて成功させる demo。 例示対象は CFStringCreateWithCString を
# bootstrap! を経由せず Apple.discover 単発で宣言する形。
#
# Usage:
#   RUBY_BOX=1 bundle exec ruby examples/discover_escape.rb

require "apple_sdk_mac"

# ★ 重要: ここでは AppleSDKMac.bootstrap! を呼ばない。
# 単一 symbol を Apple.discover で宣言 → その場で呼べる、 という escape hatch
# としての最小ケースを示す。

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
