# frozen_string_literal: true
require "test_helper"
require "apple_sdk_mac/irb_completion"

class TestIRBCompletionAutoDiscoverer < Test::Unit::TestCase
  Context = AppleSDKMac::IRBCompletion::Context
  AutoDiscoverer = AppleSDKMac::IRBCompletion::AutoDiscoverer

  class FakeKnowledgeCache
    def initialize(klass_methods: {})
      @klass_methods = klass_methods
    end
    def list_klass_methods(framework:, klass:)
      @klass_methods[[framework, klass]] || []
    end
  end

  def test_module_kind_is_no_op
    calls = []
    discoverer = AutoDiscoverer.new(
      knowledge_cache: FakeKnowledgeCache.new,
      discover_proc: ->(**args) { calls << args }
    )
    mod_ctx = Context.new("Foundation", nil, :module, "NSData")
    discoverer.run(mod_ctx, "NSData")
    assert_equal [], calls
  end

  def test_class_method_dispatches_class_method_form
    cache = FakeKnowledgeCache.new(klass_methods: {
      ["Foundation", "NSData"] => [
        {name: "dataWithContentsOfFile:", kind: "class_method"}
      ]
    })
    calls = []
    discoverer = AutoDiscoverer.new(
      knowledge_cache: cache,
      discover_proc: ->(**args) { calls << args }
    )
    ctx = Context.parse("Apple::Foundation::NSData.dataWithContentsOfFile")
    discoverer.run(ctx, "dataWithContentsOfFile")

    assert_equal 1, calls.size
    assert_equal :Foundation, calls.first[:framework]
    assert_equal :NSData, calls.first[:klass]
    assert_equal "dataWithContentsOfFile:", calls.first[:class_method]
  end

  def test_instance_method_dispatches_selector_form
    cache = FakeKnowledgeCache.new(klass_methods: {
      ["Foundation", "NSData"] => [
        {name: "length", kind: "instance_method"}
      ]
    })
    calls = []
    discoverer = AutoDiscoverer.new(
      knowledge_cache: cache,
      discover_proc: ->(**args) { calls << args }
    )
    ctx = Context.parse("Apple::Foundation::NSData.length")
    discoverer.run(ctx, "length")

    assert_equal 1, calls.size
    assert_equal "length", calls.first[:selector]
  end

  def test_swift_init_dispatches_swift_initializer_form
    cache = FakeKnowledgeCache.new(klass_methods: {
      ["Vision", "VNRecognizeTextRequest"] => [
        {name: "init()", kind: "swift_init", signature: "init()"}
      ]
    })
    calls = []
    discoverer = AutoDiscoverer.new(
      knowledge_cache: cache,
      discover_proc: ->(**args) { calls << args }
    )
    ctx = Context.parse("Apple::Vision::VNRecognizeTextRequest.init")
    discoverer.run(ctx, "init")

    assert_equal 1, calls.size
    assert_equal "init()", calls.first[:swift_initializer]
  end

  def test_swift_property_dispatches_swift_property_form
    cache = FakeKnowledgeCache.new(klass_methods: {
      ["Vision", "VNRecognizedText"] => [
        {name: "string", kind: "swift_property"}
      ]
    })
    calls = []
    discoverer = AutoDiscoverer.new(
      knowledge_cache: cache,
      discover_proc: ->(**args) { calls << args }
    )
    ctx = Context.parse("Apple::Vision::VNRecognizedText.string")
    discoverer.run(ctx, "string")

    assert_equal 1, calls.size
    assert_equal :string, calls.first[:swift_property]
    assert_equal true, calls.first[:instance]
  end

  def test_unknown_method_no_op
    calls = []
    discoverer = AutoDiscoverer.new(
      knowledge_cache: FakeKnowledgeCache.new,
      discover_proc: ->(**args) { calls << args }
    )
    ctx = Context.parse("Apple::Foundation::NSData.bogusMethod")
    discoverer.run(ctx, "bogusMethod")
    assert_equal [], calls
  end

  def test_discover_failure_propagates
    cache = FakeKnowledgeCache.new(klass_methods: {
      ["Foundation", "NSData"] => [
        {name: "length", kind: "instance_method"}
      ]
    })
    discoverer = AutoDiscoverer.new(
      knowledge_cache: cache,
      discover_proc: ->(**) { raise AppleSDKMac::CompileError, "boom" }
    )
    ctx = Context.parse("Apple::Foundation::NSData.length")
    assert_raise(AppleSDKMac::CompileError) do
      discoverer.run(ctx, "length")
    end
  end
end
