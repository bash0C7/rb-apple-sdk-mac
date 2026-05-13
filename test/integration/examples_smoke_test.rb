# frozen_string_literal: true
require "test_helper"
require "open3"

# Integration smoke for examples/. Each example is run as a subprocess so
# the gem load + dispatcher init paths exercised under RUBY_BOX=1 are the
# same code path a user invokes from the command line.
class TestExamplesSmoke < Test::Unit::TestCase
  GEM_ROOT = File.expand_path("../..", __dir__)

  def run_example(name, env: {}, timeout: 30)
    path = File.join(GEM_ROOT, "examples", name)
    skip "example missing: #{name}" unless File.exist?(path)
    out, err, status = Open3.capture3({ "RUBY_BOX" => "1" }.merge(env),
      "bundle", "exec", "ruby", path,
      chdir: GEM_ROOT)
    { stdout: out, stderr: err, exitstatus: status.exitstatus }
  end

  # Vision OCR 実 recognition。 release 水準 README L3 を直接満たす example。
  # Acceptance:
  # - examples/fixtures/ocr_hello.png コミット済 (再生成 Swift script 同梱)
  # - 出力 ocr=HELLO RUBY 完全一致 (case + spacing)
  # - 出力 observations=<N> (N ≥ 1)
  # - 出力 confidence=0.<dd> (confidence > 0)
  # - DEFERRED literal 不在
  OCR_FIXTURE_TEXT = "HELLO RUBY"
  OCR_FIXTURE_PATH = File.expand_path("../../examples/fixtures/ocr_hello.png", __dir__)

  def test_vision_ocr_recognizes_fixture_text_exactly
    skip "OCR fixture missing" unless File.exist?(OCR_FIXTURE_PATH)
    res = run_example("vision_ocr.rb")
    assert_equal 0, res[:exitstatus],
      "vision_ocr.rb exited #{res[:exitstatus]}; stderr:\n#{res[:stderr]}"
    refute_match(/DEFERRED/, res[:stdout],
      "DEFERRED 退路は禁止 (release_quality 命題)")
    assert_match(/ocr=#{Regexp.escape(OCR_FIXTURE_TEXT)}/, res[:stdout],
      "OCR result must equal fixture text exactly")
    assert_match(/observations=\d+/, res[:stdout],
      "must report observation count")
    assert_match(/confidence=0?\.\d+|confidence=1\.0/, res[:stdout],
      "must report top candidate confidence")
  end

  # CFStringCreateWithCString → CFStringGetLength → CFStringGetCString の
  # round-trip。 "hello" を Ruby String に戻せること。 autoarc box pointer は
  # CFTypeRefMarshaller の runtime_arc_unbox_cftype 経由で内部 CFString
  # pointer に unwrap される。
  def test_cf_string_create_round_trips_hello_via_autoarc_box
    res = run_example("cf_string_create.rb")
    assert_equal 0, res[:exitstatus],
      "cf_string_create.rb exited #{res[:exitstatus]}; stderr:\n#{res[:stderr]}"
    assert_match(/auto-ARC OK/, res[:stdout],
      "expected 'auto-ARC OK' message; got:\n#{res[:stdout]}")
    assert_match(/^length=5$/, res[:stdout],
      "CFStringGetLength(box) で 5 が取れる (hello)")
    assert_match(/^read_back=hello$/, res[:stdout],
      "CFStringGetCString で Ruby String 'hello' に戻せる (round-trip)")
    refute_match(/DEFERRED/, res[:stdout],
      "DEFERRED 退路は禁止 (release_quality 命題)")
    src = File.read(File.join(GEM_ROOT, "examples", "cf_string_create.rb"))
    refute_match(/CFRelease/i, src.gsub(/^#.*$/, ""),
      "manual CFRelease is forbidden in user code (comments excluded)")
  end

  # Canonical CoreMIDI client + input port + optional source-connect + short
  # event loop drain. Validates the README MIDIClientCreate path PLUS callback
  # (MIDIReadProc) routing through the CallbackPillar persistent slot table.
  # EVENT_LOOP_SECONDS=1 makes the test deterministic — exit ≤ 5s in CI.
  def test_coremidi_receive_runs_in_short_event_loop
    res = run_example("coremidi_receive.rb", env: { "EVENT_LOOP_SECONDS" => "1" })
    assert_equal 0, res[:exitstatus],
      "coremidi_receive.rb exited #{res[:exitstatus]}; stderr:\n#{res[:stderr]}"
    assert_match(/^client=\d+$/, res[:stdout],
      "expected client=<int> line; got:\n#{res[:stdout]}")
    assert_match(/^in_port=\d+$/, res[:stdout],
      "expected in_port=<int> line; got:\n#{res[:stdout]}")
    assert_match(/^done$/, res[:stdout])
  end

  # Apple Foundation framework (NSOperationQueue + NSBlockOperation)
  # 経由の真の並列実行。Ruby Thread fake と runtime fixture 退路を
  # 排除し、release 水準 README L3 を直接満たす example。
  #
  # Acceptance:
  # - examples/async_taskgroup.rb から `Thread.new` と
  #   `AppleSDKMacRuntime::Test` literal を完全消去
  # - Apple::Foundation::NSOperationQueue を直接使用 (Apple.discover 経由のみ)
  # - 出力 `results=[20, 40, 60]` (each input doubled)
  # - 出力 `parallel=true` (elapsed_ms < max(input) + 80)
  # - DEFERRED literal 不在
  def test_async_taskgroup_uses_apple_foundation_operationqueue
    src = File.read(File.join(GEM_ROOT, "examples", "async_taskgroup.rb"))
    refute_match(/Thread\.new/, src,
      "Ruby Thread fake は禁止 (release_quality 命題)")
    refute_match(/AppleSDKMacRuntime::Test/, src,
      "runtime fixture 退路は禁止")
    assert_match(/Apple::Foundation::NSOperationQueue/, src,
      "must use Apple Foundation NSOperationQueue (release 水準 README L3)")

    res = run_example("async_taskgroup.rb")
    assert_equal 0, res[:exitstatus],
      "async_taskgroup.rb exited #{res[:exitstatus]}; stderr:\n#{res[:stderr]}"
    refute_match(/DEFERRED/, res[:stdout],
      "DEFERRED 退路は禁止")
    assert_match(/results=\[20, 40, 60\]/, res[:stdout],
      "each input doubled (10*2=20, 20*2=40, 30*2=60)")
    assert_match(/parallel=true/, res[:stdout],
      "must run in parallel (elapsed_ms < max(input)+80)")
    elapsed = res[:stdout][/elapsed_ms=(\d+)/, 1].to_i
    assert elapsed < 110,
      "elapsed_ms=#{elapsed} suggests sequential (sum) execution; " \
      "expected near max(input)=30 + overhead"
  end

  # URLSession 実 HTTP download。 release 水準 README L3 を直接満たす example。
  # Acceptance:
  # - file:// 退路完全廃止 (HTTP/HTTPS スキームのみ)
  # - bytes=<N> が fixture body のバイト数と完全一致
  # - sha256=<64hex> が fixture body の SHA256 と完全一致
  # - DEFERRED 句不在
  # - HTTP fixture を smoke 内で起動 (外部 network 依存ゼロ)
  #
  # 簡易 HTTP fixture: stdlib (TCPServer + Socket) で localhost に固定 body を
  # 配信、 example に URL を ENV["URL_FIXTURE_URL"] で渡す (webrick 依存ゼロ)。
  URL_FIXTURE_BODY = ("URL fixture payload\n" * 10).freeze

  def start_url_fixture_server
    require "socket"
    require "digest"
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    body = URL_FIXTURE_BODY
    thread = Thread.new do
      loop do
        client = begin
          server.accept
        rescue
          break
        end
        begin
          while (line = client.gets)
            break if line.strip.empty?
          end
          resp = "HTTP/1.1 200 OK\r\n" \
                 "Content-Type: application/octet-stream\r\n" \
                 "Content-Length: #{body.bytesize}\r\n" \
                 "Connection: close\r\n\r\n#{body}"
          client.write(resp)
        ensure
          client.close rescue nil
        end
      end
    end
    [server, port, thread]
  end

  def test_urlsession_download_real_http_bytes_match
    require "digest"
    server, port, thread = start_url_fixture_server
    begin
      url = "http://127.0.0.1:#{port}/fixture"
      res = run_example("urlsession_download.rb",
                        env: { "T53_FIXTURE_URL" => url })
      assert_equal 0, res[:exitstatus],
        "urlsession_download.rb exited #{res[:exitstatus]}; stderr:\n#{res[:stderr]}"
      refute_match(/DEFERRED/, res[:stdout],
        "DEFERRED 退路は禁止 (release_quality 命題)")
      refute_match(/file:\/\//, res[:stdout],
        "file:// scheme は disqualified (HTTP 必須)")
      assert_match(/scheme=http/, res[:stdout],
        "must perform real HTTP via URLSession")
      assert_match(/bytes=#{URL_FIXTURE_BODY.bytesize}/, res[:stdout],
        "byte count must match fixture exactly (#{URL_FIXTURE_BODY.bytesize})")
      expected_sha = Digest::SHA256.hexdigest(URL_FIXTURE_BODY)
      assert_match(/sha256=#{expected_sha}/, res[:stdout],
        "sha256 of received body must equal fixture sha256")
    ensure
      server.close rescue nil
      thread.kill rescue nil
    end
  end

  # ObjC class method via Apple.discover(class_method:) は実呼び出しで
  # 完結すること。 emit_objc_class_method + Swift 6 init-bridge により
  # `+stringWithUTF8String:` → `NSString(utf8String: arg0)` に decoded、
  # 戻り値は +1-retained NSString pointer。 DEFERRED 退路は許可しない。
  # avspeech_synth.rb は AVFoundation Swift overlay framework を bootstrap! の
  # みで discover → init → speak まで通す。 実音声 device は CI / headless で
  # 未提供なことがあるため、 'speak issued' 行 (bootstrap が完走した証跡) を
  # 必須にし、 実再生完了 ('speak completed OK') は audio device 依存なので
  # 強制しない。
  def test_avspeech_synth_bootstrap_completes_through_speak_call
    res = run_example("avspeech_synth.rb", timeout: 35)
    assert_match(/speak issued: /, res[:stdout],
      "AVSpeechSynthesizer.init / AVSpeechUtterance.init_string / " \
      "synthesizer.speak が bootstrap! のみで通って 'speak issued:' 行に到達せなあかん。 " \
      "stderr=#{res[:stderr]}")
    refute_match(/DEFERRED/, res[:stdout],
      "DEFERRED 退路は禁止 (release_quality 命題)")
  end

  # discover_escape は Apple.discover の escape hatch を 2 通り示す:
  #   Case 1: C function 直叩き — [:opaque_ref, :cstring, :uint32] -> :opaque_ref
  #     shape で CFStringCreateWithCString を呼ぶ。 README L8 の commitment を
  #     裏付けるため、 LLM safety net に落ちず static template path で完結する
  #     ことを assert (compile_history.generator='template')。
  #   Case 2: ObjC class method — +[NSString stringWithUTF8String:] を
  #     Apple.discover(class_method:) 経由で。 emit_objc_class_method の Swift 6
  #     init-bridge で +1-retained NSString 戻り raw pointer を返す。
  def test_discover_escape_example_covers_cf_and_nsstring_paths
    res = run_example("discover_escape.rb")
    assert_equal 0, res[:exitstatus],
      "discover_escape.rb exited #{res[:exitstatus]}; stderr:\n#{res[:stderr]}"
    refute_match(/DEFERRED/, res[:stdout],
      "DEFERRED 退路は禁止 (release_quality 命題)")
    # Case 1: CF function 直叩き
    assert_match(/discover_escape: CFStringCreateWithCString returned box=\d+/,
      res[:stdout],
      "discover_escape.rb did not print expected box pointer for CF case")
    # Case 2: ObjC class method (Swift 6 init-bridge form)
    assert_match(/discover_escape: NSString\.stringWithUTF8String returned ptr=\d+/,
      res[:stdout],
      "discover_escape.rb did not print expected NSString pointer")

    # Static catalog assertion: the compiled-glue cache must record the CF
    # symbol's resolved generator as 'template' (deterministic static path),
    # not 'llm' (LLM safety net fallback). compiled_glue persists per
    # successful compile; compile_history records each attempt and is bypassed
    # when the lookup hits a cached row, so it's the wrong source for "what
    # generator produced the live glue". compiled_glue is the canonical record.
    require "apple_sdk_mac/compiled_glue_cache"
    require "apple_sdk_mac/cache_dir"
    require "rb_apple_sdk_knowledge"
    cache = AppleSDKMac::CompiledGlueCache.open(
      AppleSDKMac.cache_dir, sdk_version: AppleSDKKnowledge::SDK.version
    )
    rec = cache.lookup(framework: "CoreFoundation", symbol: "CFStringCreateWithCString")
    cache.close
    refute_nil rec,
      "compiled_glue has no row for CoreFoundation::CFStringCreateWithCString " \
      "after running discover_escape — example did not actually compile"
    assert_equal "template", rec[:generator],
      "expected static template path; got generator=#{rec[:generator].inspect} " \
      "— TemplateGenerator catalog gap for [:opaque_ref, :cstring, :uint32] -> :opaque_ref"
  end

  # piano_keyboard.rb の non-interactive smoke (引数なし起動 → list mode)。
  # CoreAudio HAL 経由の audio output device 列挙が完走することを確認。
  # 内部で AudioObjectGetPropertyDataSize / AudioObjectGetPropertyData の
  # KB record path (AudioObjectPropertyAddress Hash 形) と AVFAudio 系
  # swift_initializer / selector / swift_property の static template path が
  # 全 16 declare 通って exit 0 になることを regression guard。
  def test_piano_keyboard_no_args_lists_devices
    res = run_example("piano_keyboard.rb")
    assert_equal 0, res[:exitstatus],
      "piano_keyboard.rb (no args) exited #{res[:exitstatus]}; " \
      "stderr:\n#{res[:stderr]}"
    refute_match(/DEFERRED/, res[:stdout],
      "DEFERRED 退路は禁止 (release_quality 命題)")
    assert_match(/^Output devices:$/, res[:stdout],
      "must print 'Output devices:' header before exiting")
    assert_match(/^\s+\[\d+\]\s+.+\(uid=.+\)$/, res[:stdout],
      "must list at least one device with [N] name (uid=...) format")
  end
end
