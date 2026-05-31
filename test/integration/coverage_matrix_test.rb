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
#                          (KNOWN HOLE — template_generator に emitter arm 無し。
#                           Track-1 Task 5 で閉じる。ここでは RED が期待値)
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
  # ADDITIONAL HOLE (Task 5 候補) — 現状この kind は public path から到達不能:
  #   1. Apple.discover には kind="swift_property_setter" を生む shape が無い
  #      (discovery_shape.rb の :swift_property は常に kind="swift_property")。
  #   2. 再 build 済 Knowledge Base には swift_property_setter symbol も
  #      is_settable=1 の swift_property も 0 件 (`SELECT COUNT(*) ... = 0`)。
  #      → bootstrap! も setter method (`rate=`) を eager-define できない。
  # template_generator の emit_swift_property_setter arm 自体は存在し unit test
  # (FakeKnowledgeCache 経由) で緑だが、 実 symbol が 1 件も routing されへんため
  # round-trip は data 層で塞がれている。ここでは public setter form を呼んで
  # NoMethodError で RED になる (緑化のための weaken / skip 禁止)。
  def test_swift_property_setter_kind_round_trips
    Apple.discover(framework: :AVFoundation, klass: :AVSpeechUtterance,
                   swift_initializer: "init(string:)",
                   params: [:string], return_kind: :opaque_ref)
    Apple.discover(framework: :AVFoundation, klass: :AVSpeechUtterance,
                   swift_property: :rate, instance: true, return_kind: :float)
    utterance = Apple::AVFoundation::AVSpeechUtterance.init_string("rate probe")
    refute_nil utterance
    # public setter form。 swift_property_setter kind を eager-define する経路が
    # 存在せえへんため `rate=` は未定義で、 round-trip は成立しない。
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
  # KNOWN HOLE — template_generator の `case symbol[:kind]` に global_constant
  # arm が無く emitter が nil を返して loud-fail する。Track-1 Task 5 で閉じる
  # 設計欠陥なので、 ここでは RED が期待される (この test を緑にするための
  # weaken / skip は禁止)。
  def test_global_constant_kind_round_trips
    # NOTE: Apple.discover(symbol:) は kind を "function"/abi "c" に synthesize
    # するため global_constant emitter arm を踏まない。bootstrap! が KB から
    # eager-define した本来の kind="global_constant" method を直接呼ぶことで
    # template_generator の global_constant 経路 (= 欠落 arm) を踏ませる。
    v = Apple::CoreFoundation.kCFCoreFoundationVersionNumber
    assert_kind_of Numeric, v
    assert_operator v, :>, 0
  end
end
