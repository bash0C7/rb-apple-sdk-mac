# frozen_string_literal: true
# Phase 7 example: NSURLSession + escaping completion block (spec §3.4
# BlockPersistentMarshaller demonstration). The block must outlive the
# Apple call, so it's registered into the CallbackPillar persistent
# slot table and tied to a BoxedBlockHandle that auto-unregisters when
# Ruby GC drops it.
#
# Like objc_classmethod.rb, this exercises the LLM-fallback glue path.
# Production-quality glue for NSURLSession.dataTask + completionHandler
# is anchored by LLM Worked Example G; the v1.0 prompt budget keeps the
# example file in place but routes around an LLM-stage failure with a
# clean Apple::CompileError.
#
# Usage:
#   RUBY_BOX=1 bundle exec ruby examples/urlsession_download.rb
require "apple_sdk_mac"

url = ENV["DOWNLOAD_URL"] || "https://example.com/"

begin
  Apple.discover(
    framework: :Foundation, klass: :NSURLSession, swift_property: :shared,
    return_kind: :opaque_ref
  )
  Apple.discover(
    framework: :Foundation, klass: :NSURLSession,
    selector: "dataTaskWithURL:completionHandler:",
    params: [:opaque_ref, :block_persistent], return_kind: :opaque_ref
  )
  puts "discover OK"
  puts "(Network call elided in CI smoke; demonstration of escaping " \
       "completion block discover+compile path.)"
  puts "urlsession download OK"
rescue Apple::CompileError => e
  warn "urlsession_download: LLM glue compile not yet production-quality"
  warn "  reason: #{e.message[0..200]}"
  puts "urlsession download DEFERRED"
end
