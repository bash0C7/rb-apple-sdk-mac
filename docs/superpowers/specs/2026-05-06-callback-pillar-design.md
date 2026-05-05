# Callback Pillar Design

**Date:** 2026-05-06
**Scope:** rb-apple-sdk-mac (gem C) — `ext/apple_sdk_mac_runtime/` Swift package + glue compiler Marshaller + LLM prompt
**Status:** approved by user, ready for implementation plan
**Predecessor:** `2026-05-05-unified-marshalling-and-callback-pillar-design.md` — Verification (2026-05-06) deferred Phase 6 callback bridging to this spec.

## Context

The unified-marshalling spec landed every Marshaller kind for the README baseline except non-nil callbacks. The current `CallbackNilableMarshaller` / `CallbackNonNilMarshaller` emit:

```swift
let cb: <CallbackType>?
if argv[i] == Qnil {
    cb = nil
} else {
    rb_raise(rb_eRuntimeError, "non-nil callback not yet supported")
}
```

Acceptance criterion 3 of the predecessor spec — **"a Ruby `Proc` passed as `MIDINotifyProc` is invoked when MIDI state changes"** — requires removing that `rb_raise` and bridging the Ruby Block to a `@convention(c)` function pointer that Apple SDK frameworks can call back into.

Existing primitive in the runtime ext (`ext/apple_sdk_mac_runtime/Sources/AppleSDKMacRuntime/`):

- `CallbackBridge.swift` — holds one static `rubyDispatcher: (@convention(c) (UInt64, Int64) -> Void)?` set from C ext via `runtime_callback_set_dispatcher`. Single signature only, dispatches by `procId`.
- `apple_sdk_mac_runtime.c` — `proc_registry` (Ruby Hash, GC-rooted) maps `procId → Ruby Proc`. `ruby_callback_dispatcher(procId, arg)` looks up the proc and invokes it via `rb_proc_call_with_block`.
- `ThreadingBridge.swift` — queue-based dispatch: `enqueueFromAppleThread(procId, arg)` from any thread, `drain(timeout)` pumped from Ruby thread.

What's missing for non-nil callbacks:

1. The `@convention(c)` function pointer that the C frameworks expect cannot be synthesized from a Swift closure capturing a `procId`. Swift doesn't allow C-pointer coercion from closures with state — that's the closure-capture limit.
2. Even if (1) were solved, the dispatch infrastructure currently only knows the `(UInt64, Int64) -> Void` signature shape. Real callbacks have signatures like `MIDINotifyProc = (UnsafePointer<MIDINotification>, UnsafeMutableRawPointer?) -> Void`.
3. GVL: real Apple callbacks fire on Apple-owned threads (CoreMIDI server thread, AVAudioSession queue, …). Calling into Ruby from those threads needs either GVL acquisition or queue-based handoff to the Ruby main thread.
4. Lifetime: for **async** callbacks (`notifyProc` stored inside a long-lived `MIDIClientRef`), the registration must outlive the C call that took the callback. `defer { unregister }` does not work for this class.

## Goal

Make `Apple::CoreMIDI.MIDIClientCreate(name, ->(notif) { ... }, refcon)` work end-to-end:

1. The Ruby Proc is registered against a slot in a per-signature trampoline pool.
2. The C side receives a real `@convention(c) MIDINotifyProc` function pointer.
3. When CoreMIDI invokes the trampoline from its server thread, the trampoline routes the call to the Ruby Proc on the Ruby thread (via the existing `ThreadingBridge` queue + Ruby-side polling).
4. `test_receive_notification` is a passing smoke test: a Ruby Proc passed to `MIDIClientCreate` observes a `MIDINotification` after CoreMIDI state changes (e.g., a virtual source created in the same process).

## Non-goals (true Out of scope)

- **Synchronous-callback enumeration APIs** with a `defer { unregister }` lifetime (`CFArrayApplyFunction`, `CGPathApply`, …). They use the same pillar but are outside this spec; trivially extensible once async lands.
- **Callback signatures beyond MIDI / CoreFoundation / AVFoundation common shapes** for the initial signature catalog. The YAML can grow; the design is closed-world per-signature, not per-symbol.
- **Closure-state libffi trampolines.** That route would let any signature dispatch dynamically without a YAML, but adds a libffi build dep + ARM64 trampoline page management. Approach (ii) — pre-generated per-signature trampolines — sidesteps libffi entirely for the cost of a YAML enumeration. Approach (ii) is what this spec implements.

## Architecture

```
[Ruby]
  Apple::CoreMIDI.MIDIClientCreate("name", ->(notif){...}, nil)
       │
       ▼
[Glue Swift, codegen'd from template_generator.rb]
  argv[1] is non-nil:
       let cb_proc_id = rb_obj_id(argv[1])              // UInt64
       rb_hash_aset(__proc_registry, cb_proc_id, argv[1])  // GC-pin
       let cb_handle = AppleSDKMacRuntime.CallbackPillar.register(
           procId: cb_proc_id,
           signature: .midiNotifyProc
       )
       let cb: MIDINotifyProc? = cb_handle.fnptr        // @convention(c)
       // (no defer { unregister } — async callback; slot lifetime is leak-bounded
       //  by pool size; explicit dispose in follow-up)
       ─→ MIDIClientCreate(name, cb, refcon, &client)
       ─→ return rb_ll2inum(Int64(client))
       │
       ▼
[CoreMIDI server thread, later, async]
  trampoline `_callback_pillar_midiNotifyProc_slot_0(message, refCon)`
       │
       ▼
[CallbackPillar.swift]
  slot 0 lookup → procId → marshal `message.pointee.messageID` to Int64
       │
       ▼
[ThreadingBridge queue]
  enqueueFromAppleThread(procId, messageID)
       │
       ▼
[Ruby thread, on event_loop / threading_poll(timeout)]
  drain → ruby_callback_dispatcher(procId, messageID)
       │
       ▼
  rb_proc_call_with_block(proc, [messageID])
       │
       ▼
  ->(notif) { ... }    user Proc fires
```

## Approach (ii): signature-pre-generated trampolines

### Signature catalog (YAML)

`ext/apple_sdk_mac_runtime/callback_signatures.yml` enumerates the C function-pointer shapes that the runtime can bridge. Each entry has:

```yaml
- token: midiNotifyProc
  c_signature: "void (*)(const MIDINotification *, void *)"
  swift_signature: "@convention(c) (UnsafePointer<MIDINotification>, UnsafeMutableRawPointer?) -> Void"
  arg_marshaller: "Int64(message.pointee.messageID.rawValue)"   # message.kind → Int64
  pool_size: 4
- token: cfNotificationCallback
  c_signature: "void (*)(CFNotificationCenterRef, void *, CFStringRef, const void *, CFDictionaryRef)"
  ...
```

For MVP this spec lands one entry: `midiNotifyProc`, pool_size 4. Catalog scales to ~50 signatures across MIDI / CF / AV in a follow-up; each new entry is one YAML stanza + regenerate + rebuild. No code change in the pillar core.

### Codegen

`rake runtime:codegen_callback_pillar` reads the YAML and emits `ext/apple_sdk_mac_runtime/Sources/AppleSDKMacRuntime/CallbackPillarGenerated.swift`:

```swift
// AUTO-GENERATED — do not edit. Source: callback_signatures.yml.

extension CallbackPillar {
    enum Signature {
        case midiNotifyProc
        // ... others as YAML grows
    }
}

// === midiNotifyProc, pool_size=4 ===

nonisolated(unsafe) fileprivate var _slots_midiNotifyProc: [UInt64?] = [nil, nil, nil, nil]
fileprivate let _slots_midiNotifyProc_lock = NSLock()

@_silgen_name("_callback_pillar_midiNotifyProc_slot_0")
public func _callback_pillar_midiNotifyProc_slot_0(
    _ message: UnsafePointer<MIDINotification>,
    _ refCon: UnsafeMutableRawPointer?
) {
    guard let procId = _slots_midiNotifyProc[0] else { return }
    let arg: Int64 = Int64(message.pointee.messageID.rawValue)
    ThreadingBridge.enqueueFromAppleThread(procId: procId, arg: arg)
}
// ... slot_1 ... slot_2 ... slot_3 ...

extension CallbackPillar {
    static func _register_midiNotifyProc(procId: UInt64) -> (slot: Int, fnptr: MIDINotifyProc)? {
        _slots_midiNotifyProc_lock.lock()
        defer { _slots_midiNotifyProc_lock.unlock() }
        for (i, v) in _slots_midiNotifyProc.enumerated() where v == nil {
            _slots_midiNotifyProc[i] = procId
            let fnptrs: [MIDINotifyProc] = [
                _callback_pillar_midiNotifyProc_slot_0,
                _callback_pillar_midiNotifyProc_slot_1,
                _callback_pillar_midiNotifyProc_slot_2,
                _callback_pillar_midiNotifyProc_slot_3,
            ]
            return (i, fnptrs[i])
        }
        return nil
    }

    static func _unregister_midiNotifyProc(slot: Int) {
        _slots_midiNotifyProc_lock.lock()
        defer { _slots_midiNotifyProc_lock.unlock() }
        _slots_midiNotifyProc[slot] = nil
    }
}
```

Codegen is regenerated as part of `rake compile` (extconf prerequisite). Hand-edits to the generated file are gated by a header check + `git status` warning.

### CallbackPillar core

`ext/apple_sdk_mac_runtime/Sources/AppleSDKMacRuntime/CallbackPillar.swift` (hand-written):

```swift
import Foundation
import CoreMIDI

public enum CallbackPillar {
    public struct Handle {
        public let slot: Int
        public let signatureToken: String
        // fnptr type-erased; concrete pointer returned by per-signature register.
    }
    // Per-signature register/unregister are emitted into CallbackPillarGenerated.swift.
}

@c
public func runtime_callback_pillar_register_midi_notify(_ procId: UInt64) -> Int32 {
    guard let r = CallbackPillar._register_midiNotifyProc(procId: procId) else { return -1 }
    return Int32(r.slot)
}

@c
public func runtime_callback_pillar_get_midi_notify_fnptr(_ slot: Int32) -> UInt64 {
    let fnptrs: [MIDINotifyProc] = [
        _callback_pillar_midiNotifyProc_slot_0,
        _callback_pillar_midiNotifyProc_slot_1,
        _callback_pillar_midiNotifyProc_slot_2,
        _callback_pillar_midiNotifyProc_slot_3,
    ]
    let p = unsafeBitCast(fnptrs[Int(slot)], to: UnsafeRawPointer.self)
    return UInt64(UInt(bitPattern: p))
}

@c
public func runtime_callback_pillar_unregister_midi_notify(_ slot: Int32) {
    CallbackPillar._unregister_midiNotifyProc(slot: Int(slot))
}
```

### Ruby C-ext shim

`apple_sdk_mac_runtime.c` gains:

```c
static VALUE rb_callback_pillar_register_midi_notify(VALUE self, VALUE proc) {
    VALUE pid = ULL2NUM((uint64_t)NUM2ULL(rb_obj_id(proc)));
    rb_hash_aset(proc_registry, pid, proc);  // GC-pin via existing global hash
    int slot = runtime_callback_pillar_register_midi_notify(NUM2ULL(pid));
    if (slot < 0) rb_raise(rb_eRuntimeError, "midiNotifyProc slot pool exhausted");
    return rb_ary_new_from_args(2, INT2FIX(slot), ULL2NUM(runtime_callback_pillar_get_midi_notify_fnptr(slot)));
}

static VALUE rb_callback_pillar_unregister_midi_notify(VALUE self, VALUE slot) {
    runtime_callback_pillar_unregister_midi_notify(NUM2INT(slot));
    return Qnil;
}
```

Bound under `AppleSDKMacRuntime::CallbackPillar.register_midi_notify(proc)` → `[slot, fnptr_uint]`.

### Marshaller change

`CallbackNilableMarshaller#in_load` becomes (for MVP, only `MIDINotifyProc` route):

```swift
let <name>: <Type>?
    if argv[<i>] == Qnil {
        <name> = nil
    } else {
        let pid = rb_obj_id(argv[<i>])
        rb_hash_aset_proc_registry(pid, argv[<i>])
        let slot = runtime_callback_pillar_register_midi_notify(pid)
        if slot < 0 { rb_raise(rb_eRuntimeError, "callback slot pool exhausted") }
        let raw = runtime_callback_pillar_get_midi_notify_fnptr(slot)
        <name> = unsafeBitCast(UnsafeRawPointer(bitPattern: UInt(raw))!, to: <Type>.self)
        // Note: no unregister — this is an async-lifetime callback. Slot leaks
        // until process exit. Pool exhaustion is bounded by YAML pool_size.
    }
```

For non-MIDI signatures the Marshaller will need a per-signature dispatch table; the catalog token is derived from the C type name (`MIDINotifyProc → midiNotifyProc`). For MVP we hard-code the MIDI branch and leave the table extension for follow-up.

The HEADER gains:

```swift
@_silgen_name("rb_obj_id")
func rb_obj_id(_ v: UInt) -> UInt
@_silgen_name("rb_hash_aset_proc_registry")
func rb_hash_aset_proc_registry(_ pid: UInt, _ proc: UInt)
@_silgen_name("runtime_callback_pillar_register_midi_notify")
func runtime_callback_pillar_register_midi_notify(_ pid: UInt) -> Int32
@_silgen_name("runtime_callback_pillar_get_midi_notify_fnptr")
func runtime_callback_pillar_get_midi_notify_fnptr(_ slot: Int32) -> UInt64
```

`rb_hash_aset_proc_registry` is a small C shim added to `apple_sdk_mac_runtime.c` exposing the file-static `proc_registry` to glue Swift (since the raw `proc_registry` symbol is C-static, glue can't reach it directly).

### LLM prompt rule 9

`llm_generator.rb` rule 9 else-branch is updated to mirror the Marshaller behavior — the LLM fallback path agrees with the deterministic template path. Same Swift snippet, no `rb_raise` stub.

### Ruby-side dispatch loop

`Apple.event_loop` (existing surface in `apple_sdk_mac.rb` / `public_api.rb`) drives `runtime_threading_poll(timeout)` in a loop. The smoke test triggers a notification and pumps the loop for ~1 second:

```ruby
def test_receive_notification
  Apple.discover(framework: :CoreMIDI, symbol: :MIDIClientCreate)
  Apple.discover(framework: :CoreMIDI, symbol: :MIDISourceCreate)  # triggers SetupAdded
  Apple.discover(framework: :CoreMIDI, symbol: :MIDIClientDispose)
  Apple.discover(framework: :CoreMIDI, symbol: :MIDIEndpointDispose)

  notifs = []
  client = Apple::CoreMIDI.MIDIClientCreate("smoke-recv", ->(messageID) {
    notifs << messageID
  }, nil)
  source  = Apple::CoreMIDI.MIDISourceCreate(client, "smoke-source")
  AppleSDKMacRuntime.threading_poll(1.0)
  assert !notifs.empty?, "expected at least one notification"
  Apple::CoreMIDI.MIDIEndpointDispose(source)
  Apple::CoreMIDI.MIDIClientDispose(client)
end
```

## Lifetime / leak behavior (MVP)

For async callbacks the slot is held until process exit. With pool_size=4 per signature, the test pool is bounded; production code that creates many MIDI clients will exhaust the pool. This is a known limitation and a follow-up item.

A real solution ties slot lifetime to a Ruby wrapper around the owning Apple handle (e.g. `MIDIClientWrapper`); when the wrapper is GC'd / disposed, `_unregister_midiNotifyProc` is called. Out of scope for this spec.

## Acceptance criteria

1. `bundle exec rake compile` succeeds with `CallbackPillar.swift` + `CallbackPillarGenerated.swift` linked into `libAppleSDKMacRuntime.dylib`.
2. `test_receive_notification` PASSes: Ruby Proc observes ≥1 `messageID` after `MIDISourceCreate`.
3. `test_create_client_and_dispose` (predecessor smoke) still PASSes — non-regression.
4. `test_send_packet` (predecessor follow-up #2) still PASSes — non-regression.
5. The Marshaller behavior aligns with LLM prompt rule 9 (no `rb_raise` stub on either path).

## References

- Predecessor spec: `2026-05-05-unified-marshalling-and-callback-pillar-design.md` § Verification (2026-05-06) deferred items.
- Existing primitive: `ext/apple_sdk_mac_runtime/Sources/AppleSDKMacRuntime/CallbackBridge.swift` (single-signature) + `ThreadingBridge.swift` (queue dispatch) + `apple_sdk_mac_runtime.c` (`proc_registry` + `ruby_callback_dispatcher`).
- CoreMIDI: `MIDIClientCreate`, `MIDINotifyProc` (`<CoreMIDI/MIDIServices.h>`).
