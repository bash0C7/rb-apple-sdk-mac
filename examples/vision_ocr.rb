# frozen_string_literal: true
# T54 — Vision OCR 実 recognition example. release 水準 README L3 を直接
# 満たす (Apple Vision framework の VNRecognizeTextRequest を Apple.discover
# 経由のみで束ね、 fixture image から OCR 文字列を取り出す)。
#
# 事前宣言ゼロ。 NSData.dataWithContentsOfFile で fixture を読み、
# VNImageRequestHandler.init(data:options:) で直接 handler 構築 →
# VNRecognizeTextRequest.init() → handler.perform([request]) → results →
# topCandidates → string. 全 API は Apple.discover で discovery。
#
# Usage:
#   RUBY_BOX=1 bundle exec ruby examples/vision_ocr.rb
require "apple_sdk_mac"

fixture = File.expand_path("fixtures/ocr_hello.png", __dir__)
raise "fixture missing: #{fixture}" unless File.exist?(fixture)

# --- Foundation: NSData.dataWithContentsOfFile (file → NSData) ---
Apple.discover(framework: :Foundation, klass: :NSData,
               class_method: "dataWithContentsOfFile:",
               params: [:string], return_kind: :opaque_ref)

# --- Vision: VNImageRequestHandler.init(data:options:) ---
# Data は Swift native struct、 NSData pointer から `as Data` で bridge
# (VALUE_TYPE_NS_BRIDGES 経由)。 options は `[:]` non-Optional default。
Apple.discover(framework: :Vision, klass: :VNImageRequestHandler,
               swift_initializer: "init(data:options:)",
               params: [{kind: :opaque_ref, type: "Data"},
                        {kind: :nil_literal, type: "[VNImageOption: Any]",
                         value: "[:]"}],
               return_kind: :opaque_ref)

# --- Vision: VNRecognizeTextRequest.init() ---
Apple.discover(framework: :Vision, klass: :VNRecognizeTextRequest,
               swift_initializer: "init()",
               params: [], return_kind: :opaque_ref)

# --- Vision: handler.perform([request]) (throws bridge via :error: 末尾) ---
# Swift 6 で performRequests は perform(_:) に rename 済 (Apple importer rule:
# selector first segment の trailing word が first arg type と一致時に drop)。
# user 側で Swift bridge 名に simplify して指定する。
Apple.discover(framework: :Vision, klass: :VNImageRequestHandler,
               selector: "perform:error:",
               params: [{kind: :array_of_opaque_ref, type: "VNRequest"}],
               return_kind: :bool)

# --- Vision: request.results → [VNRecognizedTextObservation]? ---
Apple.discover(framework: :Vision, klass: :VNRecognizeTextRequest,
               swift_property: :results, instance: true,
               return_kind: {kind: :array_of_opaque_ref,
                             type: "VNRecognizedTextObservation",
                             nilable: true})

# --- Vision: observation.topCandidates(_:) → [VNRecognizedText] ---
Apple.discover(framework: :Vision, klass: :VNRecognizedTextObservation,
               selector: "topCandidates:",
               params: [:int],
               return_kind: {kind: :array_of_opaque_ref,
                             type: "VNRecognizedText",
                             nilable: false})

# --- Vision: candidate.string / candidate.confidence ---
Apple.discover(framework: :Vision, klass: :VNRecognizedText,
               swift_property: :string, instance: true, return_kind: :string)
Apple.discover(framework: :Vision, klass: :VNRecognizedText,
               swift_property: :confidence, instance: true, return_kind: :float)

# --- Pipeline ---
data = Apple::Foundation::NSData.dataWithContentsOfFile(fixture)
raise "T54: failed to read fixture" if data.nil?


handler = Apple::Vision::VNImageRequestHandler.init_data_options(data, nil)
request = Apple::Vision::VNRecognizeTextRequest.init

ok = handler.perform_error([request])
raise "T54: perform failed" unless ok

results = request.results
raise "T54: no observations" if results.nil? || results.empty?

first_obs = Apple::Vision::VNRecognizedTextObservation.from_ref(results.first)
top = first_obs.topCandidates(1)
raise "T54: no candidates" if top.empty?

candidate = Apple::Vision::VNRecognizedText.from_ref(top.first)

puts "observations=#{results.size}"
puts "confidence=#{format('%.2f', candidate.confidence)}"
puts "ocr=#{candidate.string}"
puts "vision_ocr OK"
