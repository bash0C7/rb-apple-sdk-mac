# frozen_string_literal: true
require "apple_sdk_mac"

fixture = File.expand_path("fixtures/ocr_hello.png", __dir__)
raise "fixture missing: #{fixture}" unless File.exist?(fixture)

Apple.discover(framework: :Foundation, klass: :NSData,
               class_method: "dataWithContentsOfFile:",
               params: [:string], return_kind: :opaque_ref)

Apple.discover(framework: :Vision, klass: :VNImageRequestHandler,
               swift_initializer: "init(data:options:)",
               params: [{kind: :opaque_ref, type: "Data"},
                        {kind: :nil_literal, type: "[VNImageOption: Any]",
                         value: "[:]"}],
               return_kind: :opaque_ref)

Apple.discover(framework: :Vision, klass: :VNRecognizeTextRequest,
               swift_initializer: "init()",
               params: [], return_kind: :opaque_ref)

Apple.discover(framework: :Vision, klass: :VNImageRequestHandler,
               selector: "perform:error:",
               params: [{kind: :array_of_opaque_ref, type: "VNRequest"}],
               return_kind: :bool)

Apple.discover(framework: :Vision, klass: :VNRecognizeTextRequest,
               swift_property: :results, instance: true,
               return_kind: {kind: :array_of_opaque_ref,
                             type: "VNRecognizedTextObservation",
                             nilable: true})

Apple.discover(framework: :Vision, klass: :VNRecognizedTextObservation,
               selector: "topCandidates:",
               params: [:int],
               return_kind: {kind: :array_of_opaque_ref,
                             type: "VNRecognizedText",
                             nilable: false})

Apple.discover(framework: :Vision, klass: :VNRecognizedText,
               swift_property: :string, instance: true, return_kind: :string)
Apple.discover(framework: :Vision, klass: :VNRecognizedText,
               swift_property: :confidence, instance: true, return_kind: :float)

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
