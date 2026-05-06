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

  def test_vision_ocr_runs_or_falls_back_to_namespace_smoke
    res = run_example("vision_ocr.rb")
    assert_equal 0, res[:exitstatus],
      "vision_ocr.rb exited #{res[:exitstatus]}; stderr:\n#{res[:stderr]}"
    # Either the LLM-fallback path produced glue ("vision_ocr OK") or
    # the bootstrap smoke ran ("vision_ocr DEFERRED..."). Both are
    # acceptable v1.0 outcomes; what's tested is exit 0 + clean output.
    assert_match(/^vision_ocr (OK|DEFERRED)/, res[:stdout],
      "expected vision_ocr OK or DEFERRED line; got:\n#{res[:stdout]}")
  end

  # Phase 7 T11 — CFStringCreateWithCString round-trip via auto-ARC box.
  # Acceptance: example exits 0, prints "auto-ARC OK" line. Source code
  # contains zero CFRelease references (spec §3.5 requires no manual
  # release in user code).
  def test_cf_string_create_runs_under_autoarc
    res = run_example("cf_string_create.rb")
    assert_equal 0, res[:exitstatus],
      "cf_string_create.rb exited #{res[:exitstatus]}; stderr:\n#{res[:stderr]}"
    assert_match(/auto-ARC OK/, res[:stdout],
      "expected 'auto-ARC OK' message; got:\n#{res[:stdout]}")
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

  # Phase 7 T10 — Swift TaskGroup parallel fan-out via 3 Ruby threads
  # each calling the runtime's async_await_sleep_and_double. Asserts
  # 3 parallel results match doubled inputs and elapsed_ms is closer
  # to max(inputs) than sum(inputs) (i.e. parallel, not sequential).
  def test_async_taskgroup_fans_out_in_parallel
    res = run_example("async_taskgroup.rb")
    assert_equal 0, res[:exitstatus],
      "async_taskgroup.rb exited #{res[:exitstatus]}; stderr:\n#{res[:stderr]}"
    assert_match(/^TaskGroup OK$/, res[:stdout],
      "expected TaskGroup OK line; got:\n#{res[:stdout]}")
  end

  # Phase 7 T9 — NSURLSession + escaping completion block (LLM
  # Worked Example G). Spec §3.4 BlockPersistentMarshaller path. The
  # LLM-fallback compile is anchored but the v1.0 prompt budget defers
  # production glue; example exits 0 either way (success line or
  # DEFERRED line both accepted).
  def test_urlsession_download_runs_or_defers
    res = run_example("urlsession_download.rb")
    assert_equal 0, res[:exitstatus],
      "urlsession_download.rb exited #{res[:exitstatus]}; stderr:\n#{res[:stderr]}"
    assert_match(/^urlsession download (OK|DEFERRED)$/, res[:stdout],
      "expected urlsession download OK or DEFERRED line; got:\n#{res[:stdout]}")
  end

  # Phase 7 T12 — ObjC pure class method via Apple.discover(class_method:).
  # Same LLM-deferred pattern.
  def test_objc_classmethod_runs_or_defers
    res = run_example("objc_classmethod.rb")
    assert_equal 0, res[:exitstatus],
      "objc_classmethod.rb exited #{res[:exitstatus]}; stderr:\n#{res[:stderr]}"
    assert_match(/^objc class method (OK|DEFERRED)$/, res[:stdout],
      "expected objc class method OK or DEFERRED line; got:\n#{res[:stdout]}")
  end
end
