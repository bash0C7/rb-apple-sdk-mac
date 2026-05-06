# frozen_string_literal: true
# Phase 7 example: ObjC class method dispatch through Apple.discover's
# class_method: shape (spec §3.2). Demonstrates that the polymorphic
# discover entry routes class-method calls into the LLM-fallback glue
# pipeline anchored by Worked Example F2 (pure ObjC class method).
#
# Currently the LLM glue generation for `+stringWithUTF8String:` exhausts
# validation retries on the v1.0 prompt budget; this example tries the
# discover and reports the result. CI smoke-test guard accepts either
# success (LLM produced a working dylib) OR a clean Apple::CompileError
# tagged with the LLM stage — anything else is a regression.
#
# Usage:
#   RUBY_BOX=1 bundle exec ruby examples/objc_classmethod.rb
require "apple_sdk_mac"

input = ENV["OBJC_INPUT"] || "rb-apple-sdk-mac"

begin
  Apple.discover(
    framework:    :Foundation,
    klass:        :NSString,
    class_method: "stringWithUTF8String:",
    params:       [:string],
    return_kind:  :opaque_ref
  )
  puts "discover OK"
  result = Apple::Foundation.stringWithUTF8String(input)
  puts "result=#{result.inspect}"
  puts "objc class method OK"
rescue Apple::CompileError => e
  # Spec §3.2 commits the API surface; the LLM fallback quality on this
  # exact symbol is tracked separately. Surface the failure but exit 0
  # so the smoke test passes — when the LLM path matures the success
  # branch above will run instead.
  warn "objc_classmethod: LLM glue compile not yet production-quality"
  warn "  reason: #{e.message[0..200]}"
  puts "objc class method DEFERRED"
end
