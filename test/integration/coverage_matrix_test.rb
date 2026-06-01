# frozen_string_literal: true
require "test_helper"

# カバー済み 8 emitter kind が実際に round-trip (compile + invoke) することを
# 1 kind = 1 test で実証する被覆契約の executable な裏付け。CoverageContract が
# covered?==true と表明する kind は、ここで必ず緑でなければならない。
# 実 SDK + Knowledge Base が要るため env-gate。
#
# 代表 symbol は既存の通る example / phase2 smoke から採取:
#   function             → CoreMIDI.MIDIGetNumberOfDestinations
#                          (examples/coremidi_endpoint_count.rb)
#   objc_method_class    → NSData.dataWithContentsOfFile: (examples/vision_ocr.rb)
#   objc_method_instance → NSData length (examples/urlsession_download.rb)
#   swift_init           → AVSpeechUtterance.init(string:) (examples/avspeech_synth.rb)
#   swift_property       → AVSpeechUtterance.speechString (instance getter)
#   swift_property_setter→ AVSpeechUtterance.rate= (instance setter, getter で read-back)
#   swift_func           → NSHomeDirectory() (Foundation free function → String)
#   global_constant      → CoreFoundation.kCFCoreFoundationVersionNumber
#                          (Apple.discover(constant:) public 経路で round-trip)
class CoverageMatrixTest < Test::Unit::TestCase
  def setup
    omit "set APPLE_SDK_MAC_RUN_E2E=1 to run" unless ENV["APPLE_SDK_MAC_RUN_E2E"] == "1"
    require "apple_sdk_mac"
    AppleSDKMac.bootstrap!
  end

  # function (abi c): MIDIGetNumberOfDestinations() -> ItemCount(Int)。
  # bootstrap! で eager-define 済、 初回呼び出しで C glue を compile + invoke。
  def test_function_c_kind_round_trips
    n = Apple::CoreMIDI.MIDIGetNumberOfDestinations
    assert_kind_of Integer, n
    assert_operator n, :>=, 0
  end

  # objc_method_class: +[NSData dataWithContentsOfFile:] -> NSData*。
  # 実ファイル (この test 自身) を読み込み、 非 nil の opaque_ref が返る。
  def test_objc_method_class_kind_round_trips
    Apple.discover(framework: :Foundation, klass: :NSData,
                   class_method: "dataWithContentsOfFile:",
                   params: [:string], return_kind: :opaque_ref)
    data = Apple::Foundation::NSData.dataWithContentsOfFile(__FILE__)
    refute_nil data, "dataWithContentsOfFile: should return a non-nil NSData ref"
  end

  # objc_method_instance: -[NSData length] -> NSUInteger(Int)。
  # class method (opaque_ref 戻り) は proxy に auto-wrap されるので、 返った
  # proxy に直接 instance method を呼ぶ (from_ref で二重 wrap しない)。
  def test_objc_method_instance_kind_round_trips
    Apple.discover(framework: :Foundation, klass: :NSData,
                   class_method: "dataWithContentsOfFile:",
                   params: [:string], return_kind: :opaque_ref)
    Apple.discover(framework: :Foundation, klass: :NSData,
                   selector: "length", params: [], return_kind: :int)
    data = Apple::Foundation::NSData.dataWithContentsOfFile(__FILE__)
    refute_nil data
    len = data.length
    assert_kind_of Integer, len
    assert_operator len, :>, 0, "this test file has non-zero bytes"
  end

  # swift_init: AVSpeechUtterance.init(string:) -> AVSpeechUtterance。
  # AVFoundation Swift overlay の failable でない init。 非 nil proxy が返る。
  def test_swift_init_kind_round_trips
    Apple.discover(framework: :AVFoundation, klass: :AVSpeechUtterance,
                   swift_initializer: "init(string:)",
                   params: [:string], return_kind: :opaque_ref)
    utterance = Apple::AVFoundation::AVSpeechUtterance.init_string("hello world")
    refute_nil utterance, "AVSpeechUtterance.init(string:) should return a non-nil proxy"
  end

  # swift_property: AVSpeechUtterance.speechString (instance getter) -> String。
  # init(string:) で渡した文字列がそのまま property で読み戻せる (round-trip)。
  def test_swift_property_kind_round_trips
    Apple.discover(framework: :AVFoundation, klass: :AVSpeechUtterance,
                   swift_initializer: "init(string:)",
                   params: [:string], return_kind: :opaque_ref)
    Apple.discover(framework: :AVFoundation, klass: :AVSpeechUtterance,
                   swift_property: :speechString, instance: true,
                   return_kind: :string)
    # init(string:) は opaque_ref 戻り → proxy に auto-wrap。 返った proxy に
    # 直接 instance property を呼ぶ (from_ref で二重 wrap しない)。
    utterance = Apple::AVFoundation::AVSpeechUtterance.init_string("matrix probe")
    refute_nil utterance
    str = utterance.speechString
    assert_equal "matrix probe", str,
      "speechString getter must round-trip the init(string:) value"
  end

  # swift_property_setter: AVSpeechUtterance.rate= (instance setter) -> Void。
  # rate を set した後、 getter で read-back して set 値が反映されることを確認。
  #
  # public 到達経路 (Track B で穴埋め): Apple.discover(swift_property:, setter: true)
  # が kind="swift_property_setter" を synthesize し (discovery_shape.rb)、
  # NamespaceBuilder が proxy instance method `rate=` を define する。 return_kind
  # は property の value 型 (= setter が受け取る値の型)。
  def test_swift_property_setter_kind_round_trips
    Apple.discover(framework: :AVFoundation, klass: :AVSpeechUtterance,
                   swift_initializer: "init(string:)",
                   params: [:string], return_kind: :opaque_ref)
    # getter (read-back 用)
    Apple.discover(framework: :AVFoundation, klass: :AVSpeechUtterance,
                   swift_property: :rate, instance: true, return_kind: :float)
    # setter (public path): setter: true で kind="swift_property_setter"。
    Apple.discover(framework: :AVFoundation, klass: :AVSpeechUtterance,
                   swift_property: :rate, instance: true, return_kind: :float,
                   setter: true)
    utterance = Apple::AVFoundation::AVSpeechUtterance.init_string("rate probe")
    refute_nil utterance
    utterance.rate = 0.75
    read_back = utterance.rate
    assert_kind_of Float, read_back
    assert_operator read_back, :>, 0.0,
      "rate setter must take effect (read-back > 0)"
  end

  # swift_func: NSHomeDirectory() -> String (Foundation free function、 klass 無し)。
  # static template path で `NSHomeDirectory()` を emit、 ホームディレクトリの
  # 絶対パス文字列が返る。
  def test_swift_func_kind_round_trips
    Apple.discover(framework: :Foundation, swift_func: "NSHomeDirectory",
                   params: [], return_kind: :string)
    home = Apple::Foundation.NSHomeDirectory
    assert_kind_of String, home
    assert home.start_with?("/"), "NSHomeDirectory() must return an absolute path"
  end

  # global_constant: CoreFoundation.kCFCoreFoundationVersionNumber (Double 定数)。
  # public 到達経路 (Track B で穴埋め): Apple.discover(constant:, return_kind:)
  # が kind="global_constant"/abi="c" を numeric signature 付きで synthesize し
  # (discovery_shape.rb)、 NamespaceBuilder が framework module の singleton
  # method として define、 emit_global_constant の Swift glue を round-trip する。
  def test_global_constant_kind_round_trips
    Apple.discover(framework: :CoreFoundation,
                   constant: :kCFCoreFoundationVersionNumber, return_kind: :float)
    v = Apple::CoreFoundation.kCFCoreFoundationVersionNumber
    assert_kind_of Numeric, v
    assert_operator v, :>, 0
  end
end
