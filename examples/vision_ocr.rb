# frozen_string_literal: true
# Phase 7 example: Vision framework discovery + (when LLM glue path is
# production-quality) real OCR on a fixture image. The fully-discovered
# OCR call exercises ObjC method dispatch (Worked Example F1: alloc/init
# chain) plus a noescape completion block (Worked Example G).
#
# Currently the LLM glue compile path is anchored by F1/G but the v1.0
# prompt budget keeps OCR end-to-end deferred. The bootstrap smoke
# fallback below proves the Vision namespace is populated.
#
# Usage:
#   RUBY_BOX=1 bundle exec ruby examples/vision_ocr.rb
require "apple_sdk_mac"

Apple.bootstrap!

begin
  Apple.discover(
    framework: :Vision, klass: :VNRecognizeTextRequest,
    swift_initializer: "init()", params: [], return_kind: :opaque_ref
  )
  puts "vision_ocr OCR-path discover OK"
  puts "vision_ocr OK"
rescue Apple::CompileError => e
  warn "vision_ocr: LLM glue compile not yet production-quality"
  warn "  reason: #{e.message[0..200]}"
  # Fallback smoke — Apple.bootstrap! has populated the Vision module;
  # the first 10 type constants demonstrate namespace discoverability.
  puts Apple::Vision.constants.first(10).inspect
  puts "vision_ocr DEFERRED — namespace populated"
end
