# frozen_string_literal: true
require "test-unit"
$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require "apple_sdk_mac/errors"
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
    assert fw.const_defined?(:NSString), "proxy class Apple::Foundation::NSString must be ensured"
    klass = fw.const_get(:NSString)
    assert_respond_to klass, :stringWithUTF8String,
      "singleton method derived from canonical_name part after dot"

    result = klass.stringWithUTF8String("hello")
    assert_equal "result_value", result
    assert_equal [["Foundation", "NSString.stringWithUTF8String", ["hello"]]], calls,
      "dispatcher must be called with canonical_name (= sym_record[:name])"
  end

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
    expected_method = :init_cgImage_options
    assert_respond_to klass, expected_method,
      "instance method's Ruby identifier must be the canonical part-after-dot, sanitized"

    klass.public_send(expected_method, 0xCAFE, nil)
    assert_equal [["Vision", "VNImageRequestHandler.init(cgImage:options:)", [0xCAFE, nil]]], calls
  end

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
      "swift_init Ruby identifier sanitized from canonical 'init(string:)'"
  end

  def test_proxy_classes_have_identical_shape_across_install_paths
    box_a = Module.new
    builder_a = AppleSDKMac::NamespaceBuilder.new(
      knowledge_cache: FakeKnowledge.new, target: box_a,
      dispatcher: ->(*) { :ok }
    )
    builder_a.build!
    type_const_proxy = box_a.const_get(:CoreMIDI).const_get(:MIDIClientRef)

    box_b = Module.new
    builder_b = AppleSDKMac::NamespaceBuilder.new(
      knowledge_cache: EmptyKC.new, target: box_b,
      dispatcher: ->(*) { :ok }
    )
    builder_b.install_one("Foundation", {
      name: "NSString.stringWithUTF8String",
      kind: "objc_method_class",
      objc_class: "NSString", selector: "stringWithUTF8String:"
    })
    ensure_proxy = box_b.const_get(:Foundation).const_get(:NSString)

    [type_const_proxy, ensure_proxy].each do |proxy|
      assert_respond_to proxy, :from_ref,
        "#{proxy} must expose from_ref class helper (raw → proxy instance)"
      assert_respond_to proxy, :framework,
        "#{proxy} must expose framework class helper"
      assert_respond_to proxy, :type_name,
        "#{proxy} must expose type_name class helper"
      inst = proxy.from_ref(0xDEAD_BEEF)
      assert_equal 0xDEAD_BEEF, inst.__opaque_ref,
        "#{proxy} instance must expose __opaque_ref to round-trip raw"
    end
  end

  def test_install_one_swift_init_throws_strips_throws_from_ruby_method_name
    box = Module.new
    builder = AppleSDKMac::NamespaceBuilder.new(
      knowledge_cache: EmptyKC.new, target: box,
      dispatcher: ->(framework:, symbol:, args:) { :ok }
    )
    rec = {
      name: "AVAudioFile.init(forReading:) throws",
      kind: "swift_init",
      swift_class: "AVAudioFile",
      swift_initializer: "init(forReading:) throws"
    }
    builder.install_one("AVFAudio", rec)

    klass = box.const_get(:AVFAudio).const_get(:AVAudioFile)
    assert_respond_to klass, :init_forReading,
      "throws 末尾 modifier は Ruby method 名から strip され、 `init_forReading` で呼べる"
    refute klass.singleton_methods.any? { |m| m.to_s.include?("throws") },
      "Ruby method 名に `throws` トークンが残ったら strip が壊れた印 (空白入り method 名は呼べん)"
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
      "proxy class must expose .from_ref(raw_int) class helper"

    inst = klass.from_ref(0xCAFEBABE)
    assert_kind_of klass, inst
    assert_equal 0xCAFEBABE, inst.__opaque_ref,
      "from_ref(int) instance must retain raw opaque ref"
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
      "objc_method_instance must install as proxy class instance method"

    inst.addOperations_waitUntilFinished([1, 2, 3], true)
    assert_equal [[
      "Foundation",
      "NSOperationQueue.addOperations:waitUntilFinished:",
      [0xCAFEBABE, [1, 2, 3], true]
    ]], calls,
      "receiver opaque ref must be prepended to dispatcher args"
  end

  def test_instance_method_return_klass_overrides_proxy_wrap_class
    box = Module.new
    raw = 0xCAFEBABE
    builder = AppleSDKMac::NamespaceBuilder.new(
      knowledge_cache: EmptyKC.new, target: box,
      dispatcher: ->(*) { raw }
    )
    rec = { name: "NSURLSession.dataTaskWithURL_completionHandler",
            kind: "objc_method_instance",
            objc_class: "NSURLSession",
            selector: "dataTaskWithURL:completionHandler:",
            return_kind: :opaque_ref,
            return_klass: "NSURLSessionDataTask" }
    builder.install_one("Foundation", rec)

    fw = box.const_get(:Foundation)
    session_klass = fw.const_get(:NSURLSession)
    session = session_klass.from_ref(0x1234)
    result = session.dataTaskWithURL_completionHandler(0x0, nil)
    task_klass = fw.const_get(:NSURLSessionDataTask)
    assert_kind_of task_klass, result,
      "return_klass: で指定した class の proxy instance が返るべき"
    assert_equal raw, result.__opaque_ref
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
      "swift_init with return_kind :opaque_ref must auto-wrap dispatcher result into proxy instance"
    assert_equal raw, inst.__opaque_ref,
      "wrapped instance must retain dispatcher-returned raw opaque ref"
  end

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
      "single proxy instance arg must be unwrapped to raw __opaque_ref Integer"
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
      "Array of proxy instances must be unwrapped element-wise to raw Integer Array"
  end

  def test_dispatcher_args_unwrap_proxy_instance_for_c_function_path
    box = Module.new
    calls = []
    builder = AppleSDKMac::NamespaceBuilder.new(
      knowledge_cache: EmptyKC.new, target: box,
      dispatcher: ->(framework:, symbol:, args:) {
        calls << args; :ok
      }
    )
    rec_init = { name: "NSURL.URLWithString:",
                 kind: "objc_method_class",
                 objc_class: "NSURL",
                 selector: "URLWithString:",
                 return_kind: :opaque_ref }
    builder.install_one("Foundation", rec_init)
    rec_cf = { name: "CGImageSourceCreateWithURL", kind: "function" }
    builder.install_one("ImageIO", rec_cf)

    nsurl = box.const_get(:Foundation).const_get(:NSURL)
    url_proxy = nsurl.from_ref(0xDEAD)
    box.const_get(:ImageIO).CGImageSourceCreateWithURL(url_proxy, nil)

    assert_equal [[0xDEAD, nil]], calls,
      "C function 経路でも proxy instance arg は raw Integer に unwrap"
  end

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

  def test_install_one_swift_property_setter_instance_installs_setter_method
    box = Module.new
    calls = []
    builder = AppleSDKMac::NamespaceBuilder.new(
      knowledge_cache: EmptyKC.new, target: box,
      dispatcher: ->(framework:, symbol:, args:) {
        calls << { framework: framework, symbol: symbol, args: args }; :ok
      }
    )
    rec = {
      name: "NSWindow.title=",
      kind: "swift_property_setter",
      swift_class: "NSWindow",
      swift_property: "title",
      params: [:string],
      return_kind: :void,
      instance: true
    }
    builder.install_one("AppKit", rec)

    ns_window = box.const_get(:AppKit).const_get(:NSWindow)
    win = ns_window.from_ref(0xBEEF)
    win.send(:"title=", "Hello")

    assert_equal 1, calls.size
    call = calls.first
    assert_equal "AppKit", call[:framework]
    assert_equal "NSWindow.title=", call[:symbol]
    assert_equal 0xBEEF, call[:args][0], "receiver opaque ref should be first arg"
    assert_equal "Hello", call[:args][1]
  end
end
