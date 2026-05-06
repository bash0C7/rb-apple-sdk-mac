# frozen_string_literal: true
require "test_helper"
require "apple_sdk_mac/namespace_builder"

class TestNamespaceBuilder < Test::Unit::TestCase
  class FakeKnowledge
    def list_frameworks; ["CoreMIDI"]; end
    def list_framework_symbols(framework:, kinds: nil)
      [
        { name: "MIDIClientCreate", kind: "function", abi: "c", signature: "..." },
        { name: "MIDIClientRef", kind: "struct", abi: "c", signature: "..." }
      ]
    end
  end

  def test_builds_module_with_function_method
    box = Module.new
    builder = AppleSDKMac::NamespaceBuilder.new(
      knowledge_cache: FakeKnowledge.new,
      target: box,
      dispatcher: ->(framework:, symbol:, args:) { ["dispatched", framework, symbol, args] }
    )
    builder.build!

    assert box.const_defined?(:CoreMIDI)
    coremidi = box.const_get(:CoreMIDI)
    assert_kind_of Module, coremidi
    assert_respond_to coremidi, :MIDIClientCreate
    result = coremidi.MIDIClientCreate("hi")
    assert_equal ["dispatched", "CoreMIDI", "MIDIClientCreate", ["hi"]], result
  end

  def test_struct_symbols_become_constants
    box = Module.new
    builder = AppleSDKMac::NamespaceBuilder.new(
      knowledge_cache: FakeKnowledge.new, target: box,
      dispatcher: ->(*) { nil }
    )
    builder.build!
    coremidi = box.const_get(:CoreMIDI)
    assert coremidi.const_defined?(:MIDIClientRef)
  end

  # T41 — per-symbol install API. Apple.discover synthesizes a transient
  # symbol record; install_one must put exactly that one record into the
  # namespace without re-iterating the entire DB (G2 fix). Returns the
  # installed proxy/module so Apple.discover can verify install path.
  class EmptyKC
    def list_frameworks; []; end
    def list_framework_symbols(framework:, kinds: nil); []; end
  end

  def test_install_one_creates_framework_module_for_function_kind
    box = Module.new
    calls = []
    builder = AppleSDKMac::NamespaceBuilder.new(
      knowledge_cache: EmptyKC.new, target: box,
      dispatcher: ->(framework:, symbol:, args:) {
        calls << [framework, symbol, args]; :ok
      }
    )
    rec = { name: "MIDIClientCreate", kind: "function", abi: "c" }
    builder.install_one("CoreMIDI", rec)

    assert box.const_defined?(:CoreMIDI), "framework module must be created"
    fw = box.const_get(:CoreMIDI)
    assert_respond_to fw, :MIDIClientCreate
    fw.MIDIClientCreate("hi")
    assert_equal [["CoreMIDI", "MIDIClientCreate", ["hi"]]], calls
  end

  # T41 — :method_under_klass routing for objc_method_class.
  # canonical_name "NSString.stringWithUTF8String" splits into klass+method;
  # install_one ensures Apple::Foundation::NSString proxy class exists, and
  # defines singleton method `stringWithUTF8String` that dispatches with
  # canonical_name (= sym_record[:name]).
  def test_install_one_objc_class_method_installs_method_under_klass
    box = Module.new
    calls = []
    builder = AppleSDKMac::NamespaceBuilder.new(
      knowledge_cache: EmptyKC.new, target: box,
      dispatcher: ->(framework:, symbol:, args:) {
        calls << [framework, symbol, args]; "result_value"
      }
    )
    rec = {
      name: "NSString.stringWithUTF8String",
      kind: "objc_method_class",
      objc_class: "NSString", selector: "stringWithUTF8String:"
    }
    builder.install_one("Foundation", rec)

    assert box.const_defined?(:Foundation)
    fw = box.const_get(:Foundation)
    assert fw.const_defined?(:NSString), "T41: proxy class Apple::Foundation::NSString must be ensured"
    klass = fw.const_get(:NSString)
    assert_respond_to klass, :stringWithUTF8String,
      "T41: singleton method derived from canonical_name part after dot"

    result = klass.stringWithUTF8String("hello")
    assert_equal "result_value", result
    assert_equal [["Foundation", "NSString.stringWithUTF8String", ["hello"]]], calls,
      "dispatcher must be called with canonical_name (= sym_record[:name])"
  end

  # T41 — :method_under_klass routing for objc_method_instance.
  # The proxy class is the same; the method receives an instance handle as
  # its first arg (passed through the args array unchanged at this layer —
  # the glue side handles receiver vs argument routing).
  def test_install_one_objc_instance_method_installs_under_klass
    box = Module.new
    calls = []
    builder = AppleSDKMac::NamespaceBuilder.new(
      knowledge_cache: EmptyKC.new, target: box,
      dispatcher: ->(framework:, symbol:, args:) {
        calls << [framework, symbol, args]; :inst_ok
      }
    )
    rec = {
      name: "VNImageRequestHandler.init(cgImage:options:)",
      kind: "objc_method_instance",
      objc_class: "VNImageRequestHandler",
      selector: "initWithCGImage:options:"
    }
    builder.install_one("Vision", rec)

    fw = box.const_get(:Vision)
    klass = fw.const_get(:VNImageRequestHandler)
    # Ruby method name is derived from canonical_name part after the dot,
    # sanitized for Ruby identifier safety (parens / colons → underscores).
    expected_method = :init_cgImage_options
    assert_respond_to klass, expected_method,
      "T41: instance method's Ruby identifier must be the canonical part-after-dot, sanitized"

    klass.public_send(expected_method, 0xCAFE, nil)
    assert_equal [["Vision", "VNImageRequestHandler.init(cgImage:options:)", [0xCAFE, nil]]], calls
  end

  # T41 — :method_under_klass routing for swift_init / swift_property.
  def test_install_one_swift_init_installs_under_klass
    box = Module.new
    builder = AppleSDKMac::NamespaceBuilder.new(
      knowledge_cache: EmptyKC.new, target: box,
      dispatcher: ->(framework:, symbol:, args:) { :url_ok }
    )
    rec = {
      name: "URL.init(string:)",
      kind: "swift_init",
      swift_class: "URL", swift_initializer: "init(string:)"
    }
    builder.install_one("Foundation", rec)

    klass = box.const_get(:Foundation).const_get(:URL)
    assert_respond_to klass, :init_string,
      "T41: swift_init Ruby identifier sanitized from canonical 'init(string:)'"
  end

  def test_install_one_swift_property_installs_under_klass
    box = Module.new
    builder = AppleSDKMac::NamespaceBuilder.new(
      knowledge_cache: EmptyKC.new, target: box,
      dispatcher: ->(framework:, symbol:, args:) { 42 }
    )
    rec = {
      name: "ProcessInfo.processIdentifier",
      kind: "swift_property",
      swift_class: "ProcessInfo", swift_property: "processIdentifier"
    }
    builder.install_one("Foundation", rec)

    klass = box.const_get(:Foundation).const_get(:ProcessInfo)
    assert_respond_to klass, :processIdentifier
  end

  # T52b — proxy class instance method receiver + from_ref helper.
  # spec § 4.5.1: queue.addOperations_waitUntilFinished(ops, true) のような
  # instance method 呼び出しを Apple.discover 経由で透過化する基盤。
  # 既存 install_one (objc_method_instance) は class singleton method として
  # 登録していたが、本機構では proxy class の instance method として登録し、
  # `from_ref(raw_int)` で生成した proxy instance がメソッド receiver として
  # 動作するように切替える。

  def test_proxy_class_exposes_from_ref_class_helper
    box = Module.new
    builder = AppleSDKMac::NamespaceBuilder.new(
      knowledge_cache: EmptyKC.new, target: box,
      dispatcher: ->(*) { :unused }
    )
    rec = { name: "NSOperationQueue.addOperations:waitUntilFinished:",
            kind: "objc_method_instance",
            objc_class: "NSOperationQueue",
            selector: "addOperations:waitUntilFinished:",
            return_kind: :void }
    builder.install_one("Foundation", rec)

    klass = box.const_get(:Foundation).const_get(:NSOperationQueue)
    assert_respond_to klass, :from_ref,
      "T52b: proxy class must expose .from_ref(raw_int) class helper"

    inst = klass.from_ref(0xCAFEBABE)
    assert_kind_of klass, inst
    assert_equal 0xCAFEBABE, inst.__opaque_ref,
      "T52b: from_ref(int) instance must retain raw opaque ref"
  end

  def test_objc_instance_method_routes_via_proxy_instance_with_receiver_prepend
    box = Module.new
    calls = []
    builder = AppleSDKMac::NamespaceBuilder.new(
      knowledge_cache: EmptyKC.new, target: box,
      dispatcher: ->(framework:, symbol:, args:) {
        calls << [framework, symbol, args]; :ok
      }
    )
    rec = { name: "NSOperationQueue.addOperations:waitUntilFinished:",
            kind: "objc_method_instance",
            objc_class: "NSOperationQueue",
            selector: "addOperations:waitUntilFinished:",
            return_kind: :void }
    builder.install_one("Foundation", rec)

    klass = box.const_get(:Foundation).const_get(:NSOperationQueue)
    inst = klass.from_ref(0xCAFEBABE)
    assert_respond_to inst, :addOperations_waitUntilFinished,
      "T52b: objc_method_instance must install as proxy class instance method"

    inst.addOperations_waitUntilFinished([1, 2, 3], true)
    assert_equal [[
      "Foundation",
      "NSOperationQueue.addOperations:waitUntilFinished:",
      [0xCAFEBABE, [1, 2, 3], true]
    ]], calls,
      "T52b: receiver opaque ref must be prepended to dispatcher args"
  end

  def test_swift_init_opaque_ref_return_auto_wraps_to_proxy_instance
    box = Module.new
    raw = 0xDEADBEEF
    builder = AppleSDKMac::NamespaceBuilder.new(
      knowledge_cache: EmptyKC.new, target: box,
      dispatcher: ->(*) { raw }
    )
    rec = { name: "NSOperationQueue.init()",
            kind: "swift_init",
            swift_class: "NSOperationQueue",
            swift_initializer: "init()",
            return_kind: :opaque_ref }
    builder.install_one("Foundation", rec)

    klass = box.const_get(:Foundation).const_get(:NSOperationQueue)
    inst = klass.init
    assert_kind_of klass, inst,
      "T52b: swift_init with return_kind :opaque_ref must auto-wrap dispatcher result into proxy instance"
    assert_equal raw, inst.__opaque_ref,
      "T52b: wrapped instance must retain dispatcher-returned raw opaque ref"
  end

  # T52h — proxy instance → raw opaque ref Integer unwrap on dispatcher call。
  # T52b の auto-wrap で Apple::FW::Klass.method(...) の opaque_ref 戻り値が
  # proxy instance になるが、その instance を引数として再度 instance method
  # に渡すケース (queue.addOperations_waitUntilFinished(ops, true) など) で
  # dispatcher.call に渡る args は raw Integer に unwrap されている必要がある
  # (Marshaller の Swift 側は rb_num2ull で要素を読むため Integer 必須)。

  def test_dispatcher_args_unwrap_single_proxy_instance_to_raw_int
    box = Module.new
    calls = []
    builder = AppleSDKMac::NamespaceBuilder.new(
      knowledge_cache: EmptyKC.new, target: box,
      dispatcher: ->(framework:, symbol:, args:) {
        calls << args; :ok
      }
    )
    rec_inst = { name: "NSOperationQueue.addOperation:",
                 kind: "objc_method_instance",
                 objc_class: "NSOperationQueue",
                 selector: "addOperation:",
                 return_kind: :void }
    builder.install_one("Foundation", rec_inst)

    klass = box.const_get(:Foundation).const_get(:NSOperationQueue)
    queue = klass.from_ref(0xCAFE)
    op = klass.from_ref(0xBABE)
    queue.addOperation(op)

    assert_equal [[0xCAFE, 0xBABE]], calls,
      "T52h: single proxy instance arg must be unwrapped to raw __opaque_ref Integer"
  end

  def test_dispatcher_args_unwrap_array_of_proxy_instances_recursively
    box = Module.new
    calls = []
    builder = AppleSDKMac::NamespaceBuilder.new(
      knowledge_cache: EmptyKC.new, target: box,
      dispatcher: ->(framework:, symbol:, args:) {
        calls << args; :ok
      }
    )
    rec = { name: "NSOperationQueue.addOperations:waitUntilFinished:",
            kind: "objc_method_instance",
            objc_class: "NSOperationQueue",
            selector: "addOperations:waitUntilFinished:",
            return_kind: :void }
    builder.install_one("Foundation", rec)

    klass = box.const_get(:Foundation).const_get(:NSOperationQueue)
    queue = klass.from_ref(0xCAFE)
    op1 = klass.from_ref(0x1111)
    op2 = klass.from_ref(0x2222)
    queue.addOperations_waitUntilFinished([op1, op2], true)

    assert_equal [[0xCAFE, [0x1111, 0x2222], true]], calls,
      "T52h: Array of proxy instances must be unwrapped element-wise to raw Integer Array"
  end

  # T41 — swift_func (top-level / static) maps to :method on the framework
  # module, NOT under a klass. canonical_name has no dot for top-level.
  def test_install_one_swift_func_top_level_installs_on_framework_module
    box = Module.new
    builder = AppleSDKMac::NamespaceBuilder.new(
      knowledge_cache: EmptyKC.new, target: box,
      dispatcher: ->(framework:, symbol:, args:) { :swift_ok }
    )
    rec = {
      name: "runtime_async_test_taskgroup_double",
      kind: "swift_func",
      swift_func: "runtime_async_test_taskgroup_double"
    }
    builder.install_one("Foundation", rec)
    fw = box.const_get(:Foundation)
    assert_respond_to fw, :runtime_async_test_taskgroup_double
  end
end
