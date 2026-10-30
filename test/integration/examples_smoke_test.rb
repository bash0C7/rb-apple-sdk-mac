# frozen_string_literal: true
require "test_helper"
require "open3"

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

  def test_avspeech_synth_bootstrap_completes_through_speak_call
    res = run_example("avspeech_synth.rb", timeout: 35)
    assert_match(/speak issued: /, res[:stdout],
      "AVSpeechSynthesizer.init / AVSpeechUtterance.init_string / " \
      "synthesizer.speak が bootstrap! のみで通って 'speak issued:' 行に到達せなあかん。 " \
      "stderr=#{res[:stderr]}")
    refute_match(/DEFERRED/, res[:stdout],
      "DEFERRED 退路は禁止 (release_quality 命題)")
  end

  def test_discover_escape_example_covers_cf_and_nsstring_paths
    res = run_example("discover_escape.rb")
    assert_equal 0, res[:exitstatus],
      "discover_escape.rb exited #{res[:exitstatus]}; stderr:\n#{res[:stderr]}"
    refute_match(/DEFERRED/, res[:stdout],
      "DEFERRED 退路は禁止 (release_quality 命題)")
    assert_match(/discover_escape: CFStringCreateWithCString returned box=\d+/,
      res[:stdout],
      "discover_escape.rb did not print expected box pointer for CF case")
    assert_match(/discover_escape: NSString\.stringWithUTF8String returned ptr=\d+/,
      res[:stdout],
      "discover_escape.rb did not print expected NSString pointer")

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
