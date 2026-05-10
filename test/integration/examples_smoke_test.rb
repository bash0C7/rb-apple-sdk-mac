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

  # T54 — Vision OCR 実 recognition。release 水準 README L3 を直接満たす
  # example の 1 つ。 spec § 6 acceptance:
  # - examples/fixtures/ocr_hello.png コミット済 (再生成 Swift script 同梱)
  # - 出力 ocr=HELLO RUBY 完全一致 (case + spacing)
  # - 出力 observations=<N> (N ≥ 1)
  # - 出力 confidence=0.<dd> (confidence > 0)
  # - DEFERRED literal 不在
  T54_FIXTURE_TEXT = "HELLO RUBY"
  T54_FIXTURE_PATH = File.expand_path("../../examples/fixtures/ocr_hello.png", __dir__)

  def test_vision_ocr_recognizes_fixture_text_exactly
    skip "T54 fixture missing" unless File.exist?(T54_FIXTURE_PATH)
    res = run_example("vision_ocr.rb")
    assert_equal 0, res[:exitstatus],
      "vision_ocr.rb exited #{res[:exitstatus]}; stderr:\n#{res[:stderr]}"
    refute_match(/DEFERRED/, res[:stdout],
      "T54: DEFERRED 退路は禁止 (release_quality 命題)")
    assert_match(/ocr=#{Regexp.escape(T54_FIXTURE_TEXT)}/, res[:stdout],
      "T54: OCR result must equal fixture text exactly")
    assert_match(/observations=\d+/, res[:stdout],
      "T54: must report observation count")
    assert_match(/confidence=0?\.\d+|confidence=1\.0/, res[:stdout],
      "T54: must report top candidate confidence")
  end

  # T50 — CFStringCreateWithCString → CFStringGetLength → CFStringGetCString
  # の round-trip。spec §3.9 + §6 acceptance: "hello" を Ruby String に
  # 戻せること。autoarc box pointer は CFTypeRefMarshaller の
  # runtime_arc_unbox_cftype 経由で内部 CFString pointer に unwrap される。
  def test_cf_string_create_round_trips_hello_via_autoarc_box
    res = run_example("cf_string_create.rb")
    assert_equal 0, res[:exitstatus],
      "cf_string_create.rb exited #{res[:exitstatus]}; stderr:\n#{res[:stderr]}"
    assert_match(/auto-ARC OK/, res[:stdout],
      "expected 'auto-ARC OK' message; got:\n#{res[:stdout]}")
    assert_match(/^length=5$/, res[:stdout],
      "T50: CFStringGetLength(box) で 5 が取れる (hello)")
    assert_match(/^read_back=hello$/, res[:stdout],
      "T50: CFStringGetCString で Ruby String 'hello' に戻せる (round-trip)")
    refute_match(/DEFERRED/, res[:stdout],
      "T50: DEFERRED 退路は禁止 (release_quality 命題)")
    src = File.read(File.join(GEM_ROOT, "examples", "cf_string_create.rb"))
    refute_match(/CFRelease/i, src.gsub(/^#.*$/, ""),
      "spec §3.5 forbids manual CFRelease in user code (comments excluded)")
  end

  # Phase 7 T6 — canonical CoreMIDI client + input port + optional
  # source-connect + short event loop drain. Validates the README
  # MIDIClientCreate path PLUS callback (MIDIReadProc) routing through
  # the CallbackPillar persistent slot table. EVENT_LOOP_SECONDS=1
  # makes the test deterministic — exit ≤ 5s in CI.
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

  # Phase 7 T8 — Swift async single-await round-trip via the runtime's
  # async_await_sleep_and_double test entry point. Validates the
  # DispatchSemaphore + Task + sema.wait skeleton (LLM Worked Example E1)
  # actually round-trips a value from a Swift async context to Ruby.
  def test_async_demo_runs
    res = run_example("async_demo.rb", env: { "ASYNC_SLEEP_MS" => "20" })
    assert_equal 0, res[:exitstatus],
      "async_demo.rb exited #{res[:exitstatus]}; stderr:\n#{res[:stderr]}"
    assert_match(/^result=40$/, res[:stdout],
      "expected result=40 (20*2); got:\n#{res[:stdout]}")
    assert_match(/^async OK$/, res[:stdout])
  end

  # T52 — Apple Foundation framework (NSOperationQueue + NSBlockOperation)
  # 経由の真の並列実行。Ruby Thread fake と runtime fixture (T51) 退路を
  # 排除し、release 水準 README L3 を直接満たす example。
  #
  # spec § 4 / spec § 4.3 acceptance:
  # - examples/async_taskgroup.rb から `Thread.new` と
  #   `AppleSDKMacRuntime::Test` literal を完全消去
  # - Apple::Foundation::NSOperationQueue を直接使用 (Apple.discover 経由のみ)
  # - 出力 `results=[20, 40, 60]` (each input doubled)
  # - 出力 `parallel=true` (elapsed_ms < max(input) + 80)
  # - DEFERRED literal 不在
  def test_async_taskgroup_uses_apple_foundation_operationqueue
    src = File.read(File.join(GEM_ROOT, "examples", "async_taskgroup.rb"))
    refute_match(/Thread\.new/, src,
      "T52: Ruby Thread fake は禁止 (release_quality 命題)")
    refute_match(/AppleSDKMacRuntime::Test/, src,
      "T52: runtime fixture (T51) 退路は禁止")
    assert_match(/Apple::Foundation::NSOperationQueue/, src,
      "T52: must use Apple Foundation NSOperationQueue (release 水準 README L3)")

    res = run_example("async_taskgroup.rb")
    assert_equal 0, res[:exitstatus],
      "async_taskgroup.rb exited #{res[:exitstatus]}; stderr:\n#{res[:stderr]}"
    refute_match(/DEFERRED/, res[:stdout],
      "T52: DEFERRED 退路は禁止")
    assert_match(/results=\[20, 40, 60\]/, res[:stdout],
      "T52: each input doubled (10*2=20, 20*2=40, 30*2=60)")
    assert_match(/parallel=true/, res[:stdout],
      "T52: must run in parallel (elapsed_ms < max(input)+80)")
    elapsed = res[:stdout][/elapsed_ms=(\d+)/, 1].to_i
    assert elapsed < 110,
      "T52: elapsed_ms=#{elapsed} suggests sequential (sum) execution; " \
      "expected near max(input)=30 + overhead"
  end

  # T53 — URLSession 実 HTTP download。release 水準 README L3 を直接満たす
  # example の 1 つ。 spec § 5.6 acceptance:
  # - file:// 退路完全廃止 (HTTP/HTTPS スキームのみ)
  # - bytes=<N> が fixture body のバイト数と完全一致
  # - sha256=<64hex> が fixture body の SHA256 と完全一致
  # - DEFERRED 句不在
  # - WEBrick fixture を smoke 内で起動 (外部 network 依存ゼロ)
  #
  # 簡易 HTTP fixture: stdlib (TCPServer + Socket) で localhost に固定 body を
  # 配信、example に URL を ENV["T53_FIXTURE_URL"] で渡す。webrick gem 依存ゼロ。
  T53_FIXTURE_BODY = ("T53 fixture payload v1\n" * 10).freeze

  def start_t53_fixture_server
    require "socket"
    require "digest"
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    body = T53_FIXTURE_BODY
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
    server, port, thread = start_t53_fixture_server
    begin
      url = "http://127.0.0.1:#{port}/t53"
      res = run_example("urlsession_download.rb",
                        env: { "T53_FIXTURE_URL" => url })
      assert_equal 0, res[:exitstatus],
        "urlsession_download.rb exited #{res[:exitstatus]}; stderr:\n#{res[:stderr]}"
      refute_match(/DEFERRED/, res[:stdout],
        "T53: DEFERRED 退路は禁止 (release_quality 命題)")
      refute_match(/file:\/\//, res[:stdout],
        "T53: file:// scheme は disqualified (HTTP 必須)")
      assert_match(/scheme=http/, res[:stdout],
        "T53: must perform real HTTP via URLSession")
      assert_match(/bytes=#{T53_FIXTURE_BODY.bytesize}/, res[:stdout],
        "T53: byte count must match fixture exactly (#{T53_FIXTURE_BODY.bytesize})")
      expected_sha = Digest::SHA256.hexdigest(T53_FIXTURE_BODY)
      assert_match(/sha256=#{expected_sha}/, res[:stdout],
        "T53: sha256 of received body must equal fixture sha256")
    ensure
      server.close rescue nil
      thread.kill rescue nil
    end
  end

  # T43 — ObjC class method via Apple.discover(class_method:) は実呼び出しで
  # 完結すること。spec §3.4.1 emit_objc_class_method (T42) + Swift 6 init-bridge
  # により `+stringWithUTF8String:` → `NSString(utf8String: arg0)` に decoded、
  # 戻り値は +1-retained NSString pointer。DEFERRED 退路は許可しない (spec §6 /
  # release_quality_completion_required.md)。
  # Phase 4 verification gate (v1.2 spec § 4.5 acceptance) — avspeech_synth.rb
  # は AVFoundation Swift overlay framework を bootstrap! のみで discover →
  # init → speak まで通す。 実音声 device は CI / headless で未提供なことが
  # あるため、 'speak issued' 行 (= bootstrap が完走した証跡) を必須にし、
  # 実再生完了 ('speak completed OK') は audio device 依存なので強制しない。
  def test_avspeech_synth_bootstrap_completes_through_speak_call
    res = run_example("avspeech_synth.rb", timeout: 35)
    assert_match(/speak issued: /, res[:stdout],
      "Phase 4 verification: AVSpeechSynthesizer.init / AVSpeechUtterance.init_string / " \
      "synthesizer.speak が bootstrap! のみで通って 'speak issued:' 行に到達せなあかん。 " \
      "stderr=#{res[:stderr]}")
    refute_match(/DEFERRED/, res[:stdout],
      "Phase 4 verification: DEFERRED 退路は禁止 (release_quality 命題)")
  end

  def test_objc_classmethod_actually_returns_nsstring_pointer
    res = run_example("objc_classmethod.rb")
    assert_equal 0, res[:exitstatus],
      "objc_classmethod.rb exited #{res[:exitstatus]}; stderr:\n#{res[:stderr]}"
    assert_match(/^objc class method OK$/, res[:stdout],
      "T43: expected 'objc class method OK' (no DEFERRED); got:\n#{res[:stdout]}")
    refute_match(/DEFERRED/, res[:stdout],
      "T43: DEFERRED 退路は禁止 (release_quality 命題)")
    assert_match(/^result=\d+$/, res[:stdout],
      "T43: result must be a non-zero integer (raw NSString pointer)")
  end
end
