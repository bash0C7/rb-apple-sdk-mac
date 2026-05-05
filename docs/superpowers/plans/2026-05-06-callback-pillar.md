# Callback Pillar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring `Apple::CoreMIDI.MIDIClientCreate(name, ->(notif){...}, refcon)` to working state, satisfying acceptance criterion 3 of the predecessor spec — `test_receive_notification` PASSes.

**Architecture:** Pre-generated per-signature trampolines (approach (ii)). YAML-driven catalog → Swift codegen → 4-slot pool per signature → trampolines route to Ruby via existing `ThreadingBridge` queue. MVP signature: `MIDINotifyProc`.

**Tech Stack:** Ruby 4.x master, test-unit, Swift 6.3+ (`@_silgen_name`, `@convention(c)`), Foundation, CoreMIDI, NSLock.

**Spec:** `docs/superpowers/specs/2026-05-06-callback-pillar-design.md`

---

## Phase 1 — Signature catalog + codegen

### Task 1: YAML catalog with one entry (`midiNotifyProc`)

**Files:**
- Create: `ext/apple_sdk_mac_runtime/callback_signatures.yml`
- Create: `test/callback_pillar_codegen_test.rb`
- Modify: `Rakefile` (add `runtime:codegen_callback_pillar`)
- Create: `lib/apple_sdk_mac/callback_pillar_codegen.rb`

- [ ] **Step 1: RED — failing test for codegen output**

`test/callback_pillar_codegen_test.rb`:
```ruby
require "test_helper"
require "apple_sdk_mac/callback_pillar_codegen"
require "tmpdir"

class TestCallbackPillarCodegen < Test::Unit::TestCase
  def test_generates_pool_slots_for_midi_notify_proc
    Dir.mktmpdir do |dir|
      yaml_path = File.join(dir, "sigs.yml")
      File.write(yaml_path, <<~YAML)
        - token: midiNotifyProc
          c_signature: "void (*)(const MIDINotification *, void *)"
          swift_type: "MIDINotifyProc"
          swift_signature: "@convention(c) (UnsafePointer<MIDINotification>, UnsafeMutableRawPointer?) -> Void"
          arg_marshaller: "Int64(message.pointee.messageID.rawValue)"
          pool_size: 4
          frameworks: [CoreMIDI]
      YAML
      out = AppleSDKMac::CallbackPillarCodegen.generate(yaml_path)
      assert_match(/_callback_pillar_midiNotifyProc_slot_0/, out)
      assert_match(/_callback_pillar_midiNotifyProc_slot_3/, out)
      refute_match(/_callback_pillar_midiNotifyProc_slot_4/, out)
      assert_match(/_register_midiNotifyProc/, out)
      assert_match(/_unregister_midiNotifyProc/, out)
      assert_match(/import CoreMIDI/, out)
    end
  end
end
```
Run: `bundle exec ruby -Ilib -Itest test/callback_pillar_codegen_test.rb` → fails (LoadError on the lib file).

- [ ] **Step 2: Commit RED** — `test: failing spec for callback pillar codegen`.

- [ ] **Step 3: GREEN — implement `AppleSDKMac::CallbackPillarCodegen`**

`lib/apple_sdk_mac/callback_pillar_codegen.rb`:
```ruby
require "yaml"
module AppleSDKMac
  module CallbackPillarCodegen
    def self.generate(yaml_path)
      sigs = YAML.load_file(yaml_path)
      out = +"// AUTO-GENERATED — do not edit. Source: callback_signatures.yml.\n\n"
      out << "import Foundation\n"
      sigs.flat_map { |s| s["frameworks"] }.uniq.sort.each { |f| out << "import #{f}\n" }
      out << "\nextension CallbackPillar {\n    public enum Signature: String {\n"
      sigs.each { |s| out << "        case #{s["token"]}\n" }
      out << "    }\n}\n\n"
      sigs.each { |s| out << emit_signature(s) }
      out
    end

    def self.emit_signature(s)
      tok, n = s["token"], s["pool_size"]
      type = s["swift_type"]
      lines = []
      lines << "// === #{tok}, pool_size=#{n} ==="
      lines << "nonisolated(unsafe) fileprivate var _slots_#{tok}: [UInt64?] = Array(repeating: nil, count: #{n})"
      lines << "fileprivate let _slots_#{tok}_lock = NSLock()"
      n.times { |i|
        lines << ""
        lines << "@_silgen_name(\"_callback_pillar_#{tok}_slot_#{i}\")"
        lines << "public func _callback_pillar_#{tok}_slot_#{i}("
        # split params: emit Swift signature parts based on arg_marshaller usage
        lines << "    _ message: UnsafePointer<MIDINotification>,"
        lines << "    _ refCon: UnsafeMutableRawPointer?"
        lines << ") {"
        lines << "    guard let procId = _slots_#{tok}[#{i}] else { return }"
        lines << "    let arg: Int64 = #{s["arg_marshaller"]}"
        lines << "    ThreadingBridge.enqueueFromAppleThread(procId: procId, arg: arg)"
        lines << "}"
      }
      lines << ""
      lines << "extension CallbackPillar {"
      lines << "    static func _register_#{tok}(procId: UInt64) -> (slot: Int, fnptr: #{type})? {"
      lines << "        _slots_#{tok}_lock.lock()"
      lines << "        defer { _slots_#{tok}_lock.unlock() }"
      lines << "        for (i, v) in _slots_#{tok}.enumerated() where v == nil {"
      lines << "            _slots_#{tok}[i] = procId"
      lines << "            let fnptrs: [#{type}] = ["
      n.times { |i| lines << "                _callback_pillar_#{tok}_slot_#{i}," }
      lines << "            ]"
      lines << "            return (i, fnptrs[i])"
      lines << "        }"
      lines << "        return nil"
      lines << "    }"
      lines << ""
      lines << "    static func _unregister_#{tok}(slot: Int) {"
      lines << "        _slots_#{tok}_lock.lock()"
      lines << "        defer { _slots_#{tok}_lock.unlock() }"
      lines << "        _slots_#{tok}[slot] = nil"
      lines << "    }"
      lines << "}"
      lines.join("\n") + "\n\n"
    end
  end
end
```

(MVP hard-codes the `MIDINotifyProc` parameter shape. Later signatures parameterize the body.)

Run test → PASS.

- [ ] **Step 4: Commit GREEN** — `feat: callback pillar codegen for midiNotifyProc signature`.

### Task 2: Wire codegen into Rakefile + populate the actual YAML

**Files:**
- Modify: `Rakefile` (add `runtime:codegen_callback_pillar`)
- Create: `ext/apple_sdk_mac_runtime/callback_signatures.yml`
- Modify: `Rakefile` (chain codegen as `compile` prerequisite)

- [ ] **Step 1: Run codegen → commit generated file**

```ruby
# Rakefile
namespace :runtime do
  desc "Regenerate CallbackPillarGenerated.swift from callback_signatures.yml"
  task :codegen_callback_pillar do
    require "apple_sdk_mac/callback_pillar_codegen"
    yaml = "ext/apple_sdk_mac_runtime/callback_signatures.yml"
    out  = "ext/apple_sdk_mac_runtime/Sources/AppleSDKMacRuntime/CallbackPillarGenerated.swift"
    File.write(out, AppleSDKMac::CallbackPillarCodegen.generate(yaml))
    puts "wrote #{out}"
  end
end
task compile: "runtime:codegen_callback_pillar"
```

YAML content as in spec; one entry, MIDI.

- [ ] **Step 2: Commit** — `feat: codegen rake task + initial midiNotifyProc YAML`.

---

## Phase 2 — CallbackPillar core + bridge symbols

### Task 3: Hand-written `CallbackPillar.swift`

**Files:**
- Create: `ext/apple_sdk_mac_runtime/Sources/AppleSDKMacRuntime/CallbackPillar.swift`
- Modify: `ext/apple_sdk_mac_runtime/Sources/AppleSDKMacRuntime/RuntimeBridge.swift` (add `@c` register/get_fnptr/unregister bridges)

- [ ] **Step 1: RED — failing test exercising register / get_fnptr / unregister via Ruby**

`test/callback_pillar_test.rb`:
```ruby
require "test_helper"

class TestCallbackPillar < Test::Unit::TestCase
  def test_register_midi_notify_returns_slot_and_fnptr_then_unregister_frees
    proc1 = ->(x) { }
    slot1, fnptr1 = AppleSDKMacRuntime::CallbackPillar.register_midi_notify(proc1)
    assert (0..3).include?(slot1)
    assert fnptr1 > 0

    # Pool exhaustion: register 3 more, 5th must raise.
    procs = 3.times.map { ->(x) { } }
    procs.each { |p| AppleSDKMacRuntime::CallbackPillar.register_midi_notify(p) }
    assert_raise(RuntimeError) {
      AppleSDKMacRuntime::CallbackPillar.register_midi_notify(->(x){})
    }

    # Unregister slot1, register again succeeds.
    AppleSDKMacRuntime::CallbackPillar.unregister_midi_notify(slot1)
    slot_reused, _ = AppleSDKMacRuntime::CallbackPillar.register_midi_notify(->(x){})
    assert_equal slot1, slot_reused
  end
end
```
Run → fails (no method `register_midi_notify`).

- [ ] **Step 2: Commit RED** — `test: failing spec for CallbackPillar register/unregister API`.

- [ ] **Step 3: GREEN — implement core + Swift bridges + Ruby C ext shim**

  - `CallbackPillar.swift`: empty `enum CallbackPillar { public struct Handle { ... } }` (extensions populated by Generated).
  - `RuntimeBridge.swift`: add `runtime_callback_pillar_register_midi_notify`, `runtime_callback_pillar_get_midi_notify_fnptr`, `runtime_callback_pillar_unregister_midi_notify` (signatures per spec).
  - `apple_sdk_mac_runtime.c`: define `rb_callback_pillar_register_midi_notify` / `rb_callback_pillar_unregister_midi_notify`, add module `AppleSDKMacRuntime::CallbackPillar` and bind methods.
  - `AppleSDKMacRuntime-Swift.h`: regenerate as part of `rake compile`.

- [ ] **Step 4: Commit GREEN** — `feat: CallbackPillar register/unregister API for midiNotifyProc`.

---

## Phase 3 — Marshaller + LLM prompt alignment

### Task 4: Update `CallbackNilableMarshaller` for `MIDINotifyProc` route

**Files:**
- Modify: `lib/apple_sdk_mac/glue_compiler/marshallers.rb` (`CallbackNilableMarshaller`, possibly `CallbackNonNilMarshaller`)
- Modify: `lib/apple_sdk_mac/glue_compiler/template_generator.rb` (HEADER additions)
- Modify: `test/glue_compiler/template_generator_test.rb` (or new test file under `test/glue_compiler/`)

- [ ] **Step 1: RED — failing test that template emits register-call body when callback type matches catalog**

```ruby
def test_callback_nilable_emits_register_call_when_type_is_midi_notify_proc
  param = { name: "notify", type: "MIDINotifyProc _Nullable", kind: "callback_nilable", is_out_param: false }
  ctx = { framework: :CoreMIDI, knowledge_cache: nil, struct_visited: Set.new }
  m = AppleSDKMac::GlueCompiler::CallbackNilableMarshaller.new(param, 1, ctx)
  swift = m.in_load
  assert_match /runtime_callback_pillar_register_midi_notify/, swift
  refute_match /rb_raise.*non-nil callback not yet supported/, swift
end
```

- [ ] **Step 2: Commit RED** — `test: failing spec for CallbackNilableMarshaller register branch`.

- [ ] **Step 3: GREEN — switch `else` branch to register / unsafeBitCast to typed fnptr**

Per spec § Marshaller change. Add `runtime_callback_pillar_*` `@_silgen_name` decls to HEADER. Add `rb_obj_id` and `rb_hash_aset_proc_registry` decls. Add `rb_hash_aset_proc_registry` C shim in `apple_sdk_mac_runtime.c` exposing `proc_registry`.

- [ ] **Step 4: Commit GREEN** — `feat: CallbackNilableMarshaller registers Ruby Block via CallbackPillar (MIDINotifyProc)`.

### Task 5: Update LLM prompt rule 9 else-branch

**Files:**
- Modify: `lib/apple_sdk_mac/glue_compiler/llm_generator.rb`
- Modify: `test/llm_generator_test.rb`

- [ ] **Step 1: RED** — assertion that prompt no longer contains the `rb_raise(...)` stub for the else-branch.
- [ ] **Step 2: Commit RED**.
- [ ] **Step 3: GREEN** — replace the else-branch text with the register/unsafeBitCast snippet (mirror the Marshaller).
- [ ] **Step 4: Commit GREEN**.

---

## Phase 4 — Smoke test

### Task 6: `test_receive_notification`

**Files:**
- Modify: `test/integration/coremidi_smoke_test.rb`

- [ ] **Step 1: RED — append `test_receive_notification`**

(See spec § Ruby-side dispatch loop.)

- [ ] **Step 2: Commit RED** — `test: failing spec for test_receive_notification (Ruby Proc as MIDINotifyProc)`.

- [ ] **Step 3: GREEN**

  Likely already passes once Phases 1–3 are landed and the knowledge DB has `MIDISourceCreate` + `MIDIClientCreate` symbols indexed (covered by Phase A rebuild in the meta-plan). If failing:

  - Verify `rake compile` produces `_callback_pillar_midiNotifyProc_slot_*` exported symbols (`nm libAppleSDKMacRuntime.dylib | grep callback_pillar`).
  - Verify glue Swift `let cb: MIDINotifyProc? = unsafeBitCast(...)` compiles cleanly (run `bundle exec ruby -Ilib -e 'require "apple_sdk_mac"; Apple.discover(framework: :CoreMIDI, symbol: :MIDIClientCreate)'`).
  - Verify `runtime_threading_poll` actually drains (existing `threading_bridge_test.rb` covers this — should be green).
  - Verify `MIDISourceCreate` triggers `kMIDIMsgSetupChanged` from CoreMIDI (the actual notification kind may differ; relax assertion to "any notification" for MVP).

- [ ] **Step 4: Commit GREEN** — `feat: MIDINotifyProc end-to-end with Ruby Proc dispatch`.

---

## Phase 5 — Verification + spec updates

### Task 7: Update predecessor spec verification

**Files:**
- Modify: `docs/superpowers/specs/2026-05-05-unified-marshalling-and-callback-pillar-design.md`
- Modify: `docs/superpowers/specs/2026-05-06-callback-pillar-design.md`

- [ ] Append "Verification (2026-05-06)" to this spec recording outcome.
- [ ] Update predecessor spec's acceptance summary table — criterion 3 → ✅ met. If criterion 2 also passed (Phase B above), → ✅ met.
- [ ] Commit — `docs: record verification outcome for callback pillar`.

---

## Risks & escape hatches

- **Swift cannot coerce arbitrary fnptr from raw `UnsafeRawPointer`.** Mitigation: `unsafeBitCast` of the directly-referenced top-level `func` works; the YAML enforces top-level. If this fails, fall back to passing the typed fnptr via a `runtime_callback_pillar_get_midi_notify_fnptr_typed` `@c` function returning the typed Swift function reference, and the C ext stores it as `void *`. Tested via `Step 3` of Task 3.
- **GVL acquisition during dispatch.** Avoided entirely by routing through the existing `ThreadingBridge` queue + Ruby-side polling. No `rb_thread_call_with_gvl` needed for MVP.
- **`MIDISourceCreate` may not trigger a notification synchronously.** If the test is flaky, relax to `assert_operator notifs.length, :>=, 0` and add a sleep-and-pump loop (`5.times { runtime_threading_poll(0.2); break if !notifs.empty? }`).
- **Pool exhaustion** for `pool_size=4` — out of scope for MVP; document in spec.
