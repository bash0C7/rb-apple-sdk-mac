# Complete macOS API Bridge — Phase 7 Design (network-all, release-quality)

Date: 2026-05-06
Status: written-spec — pending user review before T0 entry

## 1. Goal

Phase 7 finishes the gem to **v1.0 release quality** by satisfying every
requirement stated in `README.md` literally:

- **L3 tagline.** "Call any public Apple framework API from Ruby with no
  pre-declarations." — every public Apple framework API surface (sync C,
  variadic C, ObjC instance method, ObjC class method, Swift function,
  Swift method, Swift initializer, Swift property, Swift async, Swift
  TaskGroup / async let, Swift actor / @MainActor, completion block —
  noescape and escaping —, CF Create-rule return) is reachable through
  `Apple.discover` plus normal method dispatch.
- **L29-34 canonical Usage.** The exact 3-line snippet
  ```ruby
  require "apple_sdk_mac"
  Apple.discover(framework: :CoreMIDI, symbol: :MIDIClientCreate)
  client = Apple::CoreMIDI.MIDIClientCreate("MyClient", nil, nil)
  ```
  runs and produces a non-zero `MIDIClientRef`.
- **L42-47 Architecture.** The 9-pillar Glue Runtime, the Ruby cache
  layer, the Glue Compiler pipeline, and the Ruby runtime all keep their
  documented shape. Phase 7 *extends* existing pillars, *adds no new
  pillar*, *adds no new layer*.

Single push, single spec. `git status` clean at the end. `v1.0.0` tag
attached to the merge commit.

## 2. Scope

### 2.1 In scope (everything required to satisfy README literally)

1. **`Apple.discover` polymorphic single entry** (§3.2). One method
   accepting C-symbol, ObjC instance method, ObjC class method, Swift
   function, Swift method, Swift init, Swift property, with optional
   `type_args:` for generic resolution.
2. **Callback pillar extended to host completion blocks** (§3.3).
   Same registry, same dispatcher; new internal slot kind tags
   (`fnptr` / `block_noescape` / `block_persistent`) and a lifetime tag
   sourced from clang AST attributes. **No new pillar — count stays 9.**
3. **`BlockNilableMarshaller` and `BlockPersistentMarshaller`** (§3.4).
   AST-tag-driven: `__attribute__((noescape))` → nilable inline; absent
   → persistent + Box-tied auto-unregister.
4. **`CFTypeRefAutoARCMarshaller`** (§3.5). Reads `CF_RETURNS_RETAINED`
   from clang AST; emits `Unmanaged.takeRetainedValue()` and wraps the
   instance in a `BoxedCFType` whose deinit calls `CFRelease`. Manual
   release is removed from user-facing examples.
5. **Swift structured concurrency** (§3.6). LLM Worked Example E split
   into E1 (single `await`) / E2 (`TaskGroup`) / E3 (`async let`). E4
   covers `@MainActor.run`. ValidationGates enforces the
   `DispatchSemaphore` + `do/catch` shape.
6. **ObjC class method introspection** (§3.7). Worked Example F1
   (`+alloc` / `-init` chain) and F2 (pure class method, e.g.
   `[NSString stringWithUTF8String:]`). Worked Example G covers an ObjC
   method that takes a completion block.
7. **OSStatus / NSError → Ruby exception** for all return paths via the
   existing Error pillar; out-pointer parameters auto-allocated and
   returned as Ruby values, so the README canonical snippet returns
   `client` directly.
8. **rb-apple-sdk-knowledge coupled migration** (§5). Schema bump,
   `cf_create_rule` column, per-param `block_lifetime`, `objc_kind`,
   `swift_kind`, ingest reads clang AST attributes.
9. **Seven worked examples + macro coverage test** (§6) demonstrating
   every category above. All exit 0 in CI.
10. **§9 release-quality acceptance criteria** met in CI.

### 2.2 Out of scope (Phase 8 — none of these contradict README)

- YAML refactor of the kind catalog (cosmetic — no behavior change).
- Knowledge DB incremental rebuild optimization.
- Glue dispatch hot-path inlining beyond the §9 latency budget.

## 3. Architecture

The dispatch chain is unchanged. Phase 7 fills in nodes within the
existing layers.

```
Apple.discover(... polymorphic ...)
    │ (registers symbol record into KnowledgeCache lookup tier)
    ↓
KnowledgeCache.lookup_symbol
    │
    ├─ Structured path — TemplateGenerator
    │     kinds: string · int · bool · float · opaque_ref · cftype_ref ·
    │            cftype_ref_autoarc[NEW] · callback_nilable ·
    │            callback_non_nil · void_ptr_nilable · struct_in ·
    │            struct_out · struct_in_pointer · variadic_args ·
    │            block_nilable[NEW] · block_persistent[NEW]
    │
    └─ Free path — LLMGenerator
          ↳ Worked Examples A-G constrain the LLM.
          ↳ ValidationGates rejects malformed shapes; retry up to
            DEFAULT_MAX_LLM_RETRIES = 6.
          ↳ Cache shared with TemplateGenerator path.
```

### 3.1 Files touched

| File | Change |
|---|---|
| `ext/.../RuntimeBridge.swift` | `appleProcRegistry: UInt`, `runtime_proc_registry_init`, `runtime_proc_registry_get`. (T0, in-flight) |
| `ext/.../apple_sdk_mac_runtime.c` | `proc_registry` macro → `runtime_proc_registry_get()`. (T0, in-flight) |
| `ext/.../Package.swift` | `-Xlinker -undefined -Xlinker dynamic_lookup`. (T0, in-flight) |
| `ext/.../AppleSDKMacRuntime-Swift.h` | Regenerated by `swift build`. (T0) Rakefile auto-copies header into `ext/apple_sdk_mac_runtime/` (§3.1.1). |
| `ext/.../CallbackBridge.swift` + `CallbackPillar.swift` | Slot record gains `slot_kind` (fnptr / block_noescape / block_persistent) and `lifetime` (auto / manual). New entry points `runtime_callback_register_block_persistent`, `runtime_callback_unregister_block_persistent`. Existing fnptr API unchanged. (T2c) |
| `lib/apple_sdk_mac/glue_compiler/marshallers.rb` | `BlockNilableMarshaller` (kind=`block_nilable`), `BlockPersistentMarshaller` (kind=`block_persistent`), `CFTypeRefAutoARCMarshaller` (kind=`cftype_ref_autoarc`). Existing callback marshallers update `rb_gv_get` → `runtime_proc_registry_get` (T0). |
| `lib/apple_sdk_mac/glue_compiler/template_generator.rb` | HEADER updated; per-kind dispatch updated; struct_out auto-allocation tightened so README snippet returns `client` directly. |
| `lib/apple_sdk_mac/glue_compiler/llm_generator.rb` | INSTRUCTIONS gain Worked Examples E1/E2/E3/E4 (single await / TaskGroup / async let / @MainActor), F1/F2 (ObjC alloc-init / class method), G (ObjC + completion block). |
| `lib/apple_sdk_mac/glue_compiler/validation_gates.rb` | New rules: any glue containing `await` MUST contain `DispatchSemaphore` + `do { try await } catch { ... } sema.signal()`. Any persistent block glue MUST register against `runtime_callback_register_block_persistent`. |
| `lib/apple_sdk_mac/public_api.rb` | `Apple.discover` polymorphic body. Internal helpers `_discover_c_symbol`, `_discover_objc_method`, `_discover_swift_func`, `_discover_swift_initializer`, `_discover_swift_property`. |
| `lib/apple_sdk_mac.rb` | `Apple.discover` thin proxy and `Apple.diagnostics` proxy (§9). |
| `lib/apple_sdk_mac/diagnostics.rb` (NEW) | `Apple.diagnostics` JSON dump (§9). |
| `lib/apple_sdk_mac/errors.rb` (NEW) | `Apple::DiscoveryError`, `Apple::CompileError`, `Apple::CallError`. |
| `lib/apple_sdk_mac/compiled_glue_cache.rb` | Adds `schema_version` + `sdk_version` columns; mismatch invalidates rows. Adds `insert_seeded(symbol_record:, swift_source:)` for the manual-seed escape hatch. |
| `examples/coremidi_receive.rb` | Rewritten: explicit `proc { ... }` for `MIDIReadProc`, demonstrates connect + drain via `Apple.event_loop`. |
| `examples/vision_ocr.rb` | Rewritten: real Vision OCR on fixture image. |
| `examples/async_demo.rb` | NEW: single `await` Swift async. |
| `examples/urlsession_download.rb` | NEW: `NSURLSession.dataTask(with:completionHandler:)`, escaping completion block proof. |
| `examples/async_taskgroup.rb` | NEW: 3 parallel async fetches via `TaskGroup`. |
| `examples/cf_string_create.rb` | NEW: `CFStringCreateWithCString` round-trip, no manual `CFRelease`. |
| `examples/objc_classmethod.rb` | NEW: `+[NSString stringWithUTF8String:]` round-trip. |
| `test/fixtures/ocr_sample.png` | NEW: synthesized text image (≤30 KB). Generated at impl time via `sips`. |
| `test/integration/examples_smoke_test.rb` | Already drafted (untracked); expanded to 7 examples + README canonical snippet test. |
| `test/integration/discover_coverage_test.rb` | NEW: random sample 1000 symbols from KnowledgeCache, assert 100% kind-resolution via `Apple.discover`. |
| `test/integration/memory_leak_test.rb` | NEW: loop each example 1000 iterations, assert RSS growth ≤ 5MB. |
| `test/concurrency/concurrent_discover_test.rb` | NEW: 16 threads × 100 discovers, assert no race / no double-compile / no Hash corruption. |
| `benchmark/dispatch_overhead.rb` | NEW: cached-call dispatch latency benchmark. |
| `Rakefile` | Adds `test:release_quality` aggregate task and Swift header sync sub-task. |
| `Gemfile` / `*.gemspec` | Audit per §9. |
| `CHANGELOG.md` (NEW) | Phase 7 / v1.0.0 entry. |

No new lib/ classes beyond `errors.rb` and `diagnostics.rb`. No new
runtime Pillar files. No new C-extension TUs.

#### 3.1.1 AppleSDKMacRuntime-Swift.h sync

Currently the generated header is hand-copied from `.build/.../include`
into `ext/apple_sdk_mac_runtime/`. Phase 7 adds a `Rakefile` task
`apple:runtime:sync_header` that runs `swift build` then copies the
header into place. The C extconf rake task gains a dependency on this,
so the header is never stale.

### 3.2 `Apple.discover` polymorphic single entry

```ruby
# C function (README canonical form)
Apple.discover(framework: :CoreMIDI, symbol: :MIDIClientCreate)

# ObjC instance method
Apple.discover(framework: :Vision, klass: :VNImageRequestHandler,
               selector: "initWithCGImage:options:",
               params: [:cftype_ref, :void_ptr_nilable],
               return_kind: :opaque_ref)

# ObjC class method
Apple.discover(framework: :Foundation, klass: :NSString,
               class_method: "stringWithUTF8String:",
               params: [:string], return_kind: :opaque_ref)

# Swift function (incl. async)
Apple.discover(framework: :Foundation, swift_func: :runtime_async_test_sleep_and_double,
               params: [:int], return_kind: :int)

# Swift initializer
Apple.discover(framework: :Foundation, klass: :URL, swift_initializer: "init(string:)",
               params: [:string], return_kind: :opaque_ref)

# Swift property
Apple.discover(framework: :Foundation, klass: :ProcessInfo,
               swift_property: :processIdentifier, return_kind: :int)

# Generic type-args (Swift generic functions)
Apple.discover(framework: :Foundation, swift_func: :decode,
               type_args: [:User], params: [:string], return_kind: :opaque_ref)
```

Internal dispatch (`public_api.rb`):

```ruby
def self.discover(framework:, **opts)
  case
  when opts.key?(:symbol)              then _discover_c_symbol(framework, **opts)
  when opts.key?(:class_method)        then _discover_objc_method(framework, kind: :class, **opts)
  when opts.key?(:selector)            then _discover_objc_method(framework, kind: :instance, **opts)
  when opts.key?(:swift_initializer)   then _discover_swift_initializer(framework, **opts)
  when opts.key?(:swift_property)      then _discover_swift_property(framework, **opts)
  when opts.key?(:swift_func)          then _discover_swift_func(framework, **opts)
  else raise Apple::DiscoveryError, "Apple.discover requires one of: symbol, selector, class_method, swift_func, swift_initializer, swift_property"
  end
end
```

Each `_discover_*` synthesizes a symbol record with the proper `kind`
(`function` / `objc_method_instance` / `objc_method_class` /
`swift_func` / `swift_init` / `swift_property`) and registers it into
the transient KnowledgeCache lookup tier. `TemplateGenerator.generate`
short-circuits unless `kind == "function" && abi == "c"`; everything
else falls to `LLMGenerator` anchored by the matching Worked Example.

The README's canonical 3-line snippet hits `_discover_c_symbol`
(framework symbol DB has `MIDIClientCreate` already; out-param
auto-allocation in TemplateGenerator returns `client` directly).

### 3.3 Callback pillar extension (no new pillar)

Existing `CallbackPillar` slot table gets two extra fields:

```swift
struct CallbackSlot {
    var procId: UInt64
    var slotKind: SlotKind        // .fnptr | .blockNoescape | .blockPersistent
    var lifetime: Lifetime        // .auto | .manual
    var thunk: UnsafeRawPointer   // C fnptr OR @convention(block) thunk
}
```

Three entry points (existing fnptr ones unchanged):

```swift
@c public func runtime_callback_register_block_persistent(_ procId: UInt64) -> UInt64
@c public func runtime_callback_unregister_block_persistent(_ slotId: UInt64)
@c public func runtime_callback_release_auto_block(_ slotId: UInt64) // called by BoxedBlockHandle deinit
```

A `BoxedBlockHandle` Ruby Box wraps `slotId`; its deinit calls
`runtime_callback_release_auto_block` so escape blocks released by Ruby
GC no longer leak. Manual lifetime path exposes
`Apple.unregister_block(boxed_handle)` for the rare cases where the
caller wants explicit control.

### 3.4 Block Marshallers (AST-tag driven)

Two new Marshallers in `marshallers.rb`:

**`BlockNilableMarshaller` (kind=`block_nilable`)** — clang AST shows
`__attribute__((noescape))` on the param. Inline `@convention(block)`
literal lives on the Swift stack:

```swift
let cb_block: (@convention(block) (NSError?) -> Void)?
if argv[i] == Qnil { cb_block = nil } else {
    let pid_v = rb_obj_id(argv[i])
    rb_hash_aset(runtime_proc_registry_get(), pid_v, argv[i])
    let pid_u = rb_num2ull(pid_v)
    cb_block = { (err: NSError?) in
        ThreadingBridge.enqueueFromAppleThread(procId: pid_u, arg: err == nil ? 0 : -1)
    }
}
```

**`BlockPersistentMarshaller` (kind=`block_persistent`)** — clang AST
shows no `noescape`. The block must outlive the call:

```swift
let cb_handle: BoxedBlockHandle?
if argv[i] == Qnil { cb_handle = nil } else {
    let pid_u = rb_num2ull(rb_obj_id(argv[i]))
    rb_hash_aset(runtime_proc_registry_get(), rb_obj_id(argv[i]), argv[i])
    let slotId = runtime_callback_register_block_persistent(pid_u)
    cb_handle = BoxedBlockHandle(slotId: slotId)
}
```

The block thunk captured by `runtime_callback_register_block_persistent`
hands the call back to `ThreadingBridge.enqueueFromAppleThread` exactly
like the noescape path. Differs only in storage (slot table) and
lifetime (Box-tied).

### 3.5 CFTypeRefAutoARCMarshaller (CF Create rule)

Knowledge DB symbol record gains `cf_create_rule: bool`, populated at
ingest time from clang AST `CF_RETURNS_RETAINED` /
`CF_RETURNS_NOT_RETAINED` attributes. Naming-prefix heuristic
("Create" / "Copy") fills the gap when the attribute is missing;
otherwise default `false`.

For return kind `cftype_ref_autoarc`:

```swift
let raw = <call into Apple framework returning CFType>
let unmanaged = Unmanaged<CFType>.fromOpaque(UnsafeRawPointer(raw))
let boxed = BoxedCFType(retained: unmanaged.takeRetainedValue())
return rb_ull2inum(UInt64(UInt(bitPattern:
    Unmanaged.passRetained(boxed).toOpaque())))
```

`BoxedCFType` is a Swift class; its `deinit` calls `CFRelease`. The
Ruby-visible value is the `BoxedCFType` opaque pointer; when the Ruby
Box GC's, the Swift class deinit fires and CF is released. Users do
not call `CFRelease`.

### 3.6 Async patterns (Worked Example E1-E4)

All `await`-bearing glue follows this fixed shape (enforced by
ValidationGates):

```swift
let sema = DispatchSemaphore(value: 0)
var result: <T>?
var captured: Error?
Task {
    do { result = try await <body> }
    catch { captured = error }
    sema.signal()
}
sema.wait()
if let e = captured {
    rb_raise(rb_eRuntimeError, "\(e)"); return Qnil
}
return marshal(result!)
```

E1: single `await`. E2: `TaskGroup` — `body` becomes
`try await withThrowingTaskGroup(...) { group in ... try await group.waitForAll() }`.
E3: `async let a = ...; async let b = ...; let (x, y) = await (a, b)`.
E4: `await MainActor.run { ... }` for `@MainActor`-isolated work.

ValidationGates rejects any `await`-bearing glue that does not match
this skeleton. LLM is constrained but not nondeterministic — the
template is fixed, the LLM only fills `<body>` and `<T>`.

### 3.7 ObjC method dispatch (instance + class method)

Worked Examples F1, F2, G in INSTRUCTIONS:

**F1 (`+alloc` / `-init`):**

```swift
import Vision
@c
public func glue_<id>_VNImageRequestHandler_initWithCGImage_options(
    _ argv: UnsafePointer<UInt>, _ argc: Int32
) -> UInt {
    let img = unsafeBitCast(OpaquePointer(bitPattern: UInt(rb_num2ull(argv[0])))!,
                             to: CGImage.self)
    let handler = VNImageRequestHandler(cgImage: img, options: [:])
    let raw = Unmanaged.passRetained(handler).toOpaque()
    return rb_ull2inum(UInt64(UInt(bitPattern: raw)))
}
```

**F2 (pure class method):**

```swift
import Foundation
@c
public func glue_<id>_NSString_stringWithUTF8String(
    _ argv: UnsafePointer<UInt>, _ argc: Int32
) -> UInt {
    let cstr = ruby_string_to_cstring(argv[0])
    guard let s = NSString(utf8String: cstr) else { return Qnil }
    let raw = Unmanaged.passRetained(s).toOpaque()
    return rb_ull2inum(UInt64(UInt(bitPattern: raw)))
}
```

**G (ObjC method that takes a completion block):**

```swift
@c
public func glue_<id>_VNImageRequestHandler_performRequests(
    _ argv: UnsafePointer<UInt>, _ argc: Int32
) -> UInt {
    let handler = unsafeBitCast(OpaquePointer(bitPattern: UInt(rb_num2ull(argv[0])))!,
                                 to: VNImageRequestHandler.self)
    let request = unsafeBitCast(...)
    do {
        try handler.perform([request])
        return marshal(request.results ?? [])
    } catch let e as NSError {
        rb_raise(rb_eRuntimeError, "\(e.localizedDescription)")
        return Qnil
    }
}
```

### 3.8 ValidationGates additions

| Gate | Rule |
|---|---|
| async-shape | `await`-bearing glue must contain `DispatchSemaphore` + `Task { ... }` + `do { try await } catch { captured = error }` + `sema.signal()` + `sema.wait()` + post-wait `captured` raise. |
| persistent-block-shape | `block_persistent` glue must call `runtime_callback_register_block_persistent` and produce a `BoxedBlockHandle`. |
| autoarc-shape | `cftype_ref_autoarc` glue must call `Unmanaged.takeRetainedValue()` and box into `BoxedCFType`, never `CFRelease`. |
| objc-bridge-shape | `objc_method_*` glue must `import` the framework module and use Swift's bridged class name (no manual `objc_msgSend`). |
| existing | allowed-imports / banned-APIs / glue surface unchanged. |

## 4. TDD decomposition

Each row = independent commits (RED, GREEN, optional REFACTOR). Total:
50–60 commits.

| # | Task | RED | GREEN |
|---|---|---|---|
| **T0** | proc_registry → Swift dylib (in-flight) | `test_receive_notification` already red. Pin as the regression gate; no new RED test required (existing 4 tests cover the surface). | Land RuntimeBridge / C-ext / Package.swift / marshallers.rb / template_generator.rb together; all 4 gating tests green. |
| **T1** | Block AST detection in classifier (knowledge gem) | `test_kind.rb` — `Block (^)` AST + `noescape` attr → `block_nilable`; absent attr → `block_persistent`. | `kind.rb` adds `(^)` branch + attr reader; `KIND_VOCABULARY` extended. |
| **T2a** | `BlockNilableMarshaller` | `template_generator_test.rb` — kind=`block_nilable` produces stack-local `@convention(block)`. | Marshaller class + REGISTRY entry. |
| **T2b** | `BlockPersistentMarshaller` | `template_generator_test.rb` — kind=`block_persistent` produces `runtime_callback_register_block_persistent` + `BoxedBlockHandle`. | Marshaller class + REGISTRY entry. |
| **T2c** | Callback pillar slot extension | `callback_pillar_test.rb` — `runtime_callback_register_block_persistent` returns slot id; deinit path releases via `runtime_callback_release_auto_block`. | `CallbackPillar.swift` extension. |
| **T3a** | LLM Worked Examples E1/E2/E3/E4 | `llm_generator_test.rb` — INSTRUCTIONS contains all 4 async patterns. | `llm_generator.rb` updated. |
| **T3b** | LLM Worked Examples F1/F2/G | `llm_generator_test.rb` — INSTRUCTIONS contains alloc-init, class method, ObjC + block. | `llm_generator.rb` updated. |
| **T3c** | ValidationGates async + block + autoarc shapes | `validation_gates_test.rb` — malformed glue rejected; well-formed accepted. | `validation_gates.rb` updated. |
| **T4** | `CFTypeRefAutoARCMarshaller` | `template_generator_test.rb` — kind=`cftype_ref_autoarc` produces `Unmanaged.takeRetainedValue` + `BoxedCFType`. | Marshaller class + REGISTRY entry; `BoxedCFType` Swift class added to ARC pillar (existing file). |
| **T5** | `Apple.discover` polymorphic | `public_api_test.rb` — every entry shape (symbol / selector / class_method / swift_func / swift_initializer / swift_property / type_args) registers correct kind. | `public_api.rb` body. |
| **T6** | examples/coremidi_receive.rb | `examples_smoke_test.rb` — exit 0 in ~5s, "client=" output. | Example rewritten. |
| **T7** | examples/vision_ocr.rb + fixture | `examples_smoke_test.rb` — non-empty result array. | Example rewritten. |
| **T8** | examples/async_demo.rb | `examples_smoke_test.rb` — numeric output. | Example added. |
| **T9** | examples/urlsession_download.rb | `examples_smoke_test.rb` — file size > 0, "downloaded=" output. | Example added. |
| **T10** | examples/async_taskgroup.rb | `examples_smoke_test.rb` — 3 parallel results. | Example added. |
| **T11** | examples/cf_string_create.rb | `examples_smoke_test.rb` — round-trip string match. | Example added. |
| **T12** | examples/objc_classmethod.rb | `examples_smoke_test.rb` — `+stringWithUTF8String:` round-trip. | Example added. |
| **T13** | discover_coverage_test (macro) | sample 1000 symbols → `Apple.discover` resolves all to a known kind. | Coverage test passes. |
| **T14** | rb-apple-sdk-knowledge schema migration | `store_test.rb` — `cf_create_rule`, per-param `block_lifetime`, `objc_kind`, `swift_kind` populated by ingest from a synthetic SDK fixture. | Schema bump + ingest extension landed first; mac gem `Gemfile` knowledge ref bumped. |
| **T15** | CompiledGlueCache invalidation | `compiled_glue_cache_test.rb` — schema_version mismatch triggers row eviction. | Cache class extended. |
| **T16** | README canonical snippet test | `test/integration/readme_canonical_test.rb` — runs L26-34 verbatim. | Pass. |
| **T17** | Memory leak test | `memory_leak_test.rb` — RSS growth ≤ 5MB after 1000-iter loop of all examples. | Pass. |
| **T18** | Concurrent discover test | `concurrent_discover_test.rb` — 16 threads × 100 discovers, no race. | Pass. |
| **T19** | Diagnostics + Errors + dispatch overhead bench | `diagnostics_test.rb` / `errors_test.rb` / benchmark threshold. | All landed. |
| **T20** | Gemspec audit + CHANGELOG.md + Rakefile aggregate | `rake test:release_quality` runs T0-T19 acceptance + benchmark regression. | Pass. |

T0 unblocks T2a-T2c; T14 unblocks T1, T13. Otherwise T1-T20 can be
worked roughly in order.

## 5. rb-apple-sdk-knowledge coupled migration

Bumped to `SCHEMA_VERSION = 3`. Migration path:

1. Add columns: `cf_create_rule INTEGER DEFAULT 0`, `objc_kind TEXT`,
   `swift_kind TEXT` to `symbols`.
2. Per-param `block_lifetime` joins the existing `parameters_json` blob
   (no new column — JSON shape extension).
3. `importer/header_parser.rb` reads clang AST attributes
   `CF_RETURNS_RETAINED`, `CF_RETURNS_NOT_RETAINED`,
   `__attribute__((noescape))`, `NS_RETURNS_RETAINED`.
4. `importer/swift_interface_parser.rb` detects `async` keyword,
   `@MainActor` isolation, generic `<T>` type params.
5. `reclassifier.rb` `KIND_VOCABULARY` gains `block_nilable`,
   `block_persistent`, `cftype_ref_autoarc`, `objc_method_instance`,
   `objc_method_class`, `swift_func`, `swift_init`, `swift_property`.
6. `rake apple:knowledge:rebuild` aware of schema migration: bumps
   `schema_meta` row and triggers full re-ingest if old version
   detected.

Knowledge gem ships first; mac gem `Gemfile` bumps the ref before T1.

## 6. Examples + macro coverage

Verification suite:

| # | Example | Demonstrates |
|---|---|---|
| 1 | `coremidi_receive.rb` | sync C function + callback (fnptr) + opaque ref + struct out |
| 2 | `vision_ocr.rb` | ObjC method + sync completion block (noescape) + cftype_ref autoarc |
| 3 | `async_demo.rb` | Swift `async` single await |
| 4 | `urlsession_download.rb` | escaping completion block (persistent) + Box-tied lifetime |
| 5 | `async_taskgroup.rb` | `TaskGroup` + structured concurrency + ValidationGates async-shape |
| 6 | `cf_string_create.rb` | CF Create rule auto-ARC, no manual `CFRelease` |
| 7 | `objc_classmethod.rb` | ObjC class method introspection (`+stringWithUTF8String:`) |

Macro coverage:
`test/integration/discover_coverage_test.rb` random-samples 1000
symbols from KnowledgeCache, calls `Apple.discover` for each, asserts
kind resolved (no LLM call required — kind tag must be derivable from
DB record alone). Ensures every category in the catalog is reachable.

## 7. Verification template

When implementation is complete, append to this file:

```
## Verification (YYYY-MM-DD)

### rake test:release_quality
- rake test                                        — N tests, M asserts, 0 failures, 0 errors
- examples_smoke_test.rb                           — 7/7 exit 0
- readme_canonical_test.rb                         — pass
- discover_coverage_test.rb                        — 1000/1000 resolved
- memory_leak_test.rb                              — RSS Δ = X MB (≤ 5)
- concurrent_discover_test.rb                      — 16t × 100 — pass
- benchmark/dispatch_overhead.rb                   — cached-call p99 = X µs (≤ 200)
- gemspec audit                                    — pass
- CHANGELOG.md                                     — Phase 7 entry present

### Examples
- coremidi_receive.rb       — exit 0 in ~5s
- vision_ocr.rb             — recognized strings: ["…"]
- async_demo.rb             — result=<value>
- urlsession_download.rb    — downloaded=<bytes>
- async_taskgroup.rb        — 3 parallel results
- cf_string_create.rb       — round-trip OK, no manual CFRelease
- objc_classmethod.rb       — round-trip OK

### Carry-over
持ち越し: 0
```

## 8. What this phase deliberately does not change

- The 9-pillar split (Ref Table, Marshal, Callback, ARC, Error, Async,
  Threading, RunLoop, Conformance) — count and names locked. Phase 7
  *extends* Callback and ARC pillars; adds no new pillar.
- `Apple` Box bootstrap, NamespaceBuilder, Dispatcher, GlueLoader
  internal contracts.
- The compile cache schema's primary structure (only invalidation
  metadata added).
- swiftc invocation flags (only `Package.swift` adds
  `-undefined dynamic_lookup` for the runtime dylib's Swift target).

## 9. Release-quality acceptance criteria

`v1.0.0` tag is permitted only after every row passes in CI.

| Criterion | Acceptance |
|---|---|
| **README canonical snippet** | `test/integration/readme_canonical_test.rb` runs README L26-34 verbatim and asserts `client` is non-zero. |
| **First-call latency budget** | Uncached `Apple.discover` + first call ≤ 8s (LLM-fallback worst case); template path only ≤ 2s. Measured by `benchmark/discover_latency.rb`. |
| **Cached-call latency budget** | Dispatch p99 ≤ 200µs after cache hit. Measured by `benchmark/dispatch_overhead.rb`. CI guards regression. |
| **Memory leak budget** | `test/integration/memory_leak_test.rb` runs each example 1000× in a loop; RSS growth ≤ 5MB. |
| **Thread safety** | `test/concurrency/concurrent_discover_test.rb` — 16 threads × 100 discovers + dispatches against shared cache, registry, dispatcher; no race, no double-compile, no Hash corruption. |
| **Error UX** | LLM exhaust → `Apple::DiscoveryError` (symbol name, fail reason, last swiftc stderr tail). Compile failure → `Apple::CompileError`. Apple-side runtime failure → `Apple::CallError`. Raw Swift compile errors are not surfaced to user-level rescue. |
| **Cache invalidation** | Knowledge DB `schema_version` and `sdk_version` written into `compiled_glue_cache`; mismatch evicts rows automatically on next access. |
| **Diagnostics** | `Apple.diagnostics` returns JSON: cache stats / recent LLM attempts (last 16) / last 16 validation failures / pillar runtime stats. Sufficient for issue reproduction. |
| **Gemspec audit** | `summary`, `description`, `homepage`, `license=MIT`, `runtime_dependencies` (`rb-foundation-model-mac`, `rb-apple-sdk-knowledge`, `swift_gem` with version pins), `files` allowlist (no fixture cruft), `required_ruby_version` constraint per README. |
| **CHANGELOG.md** | Phase 7 / v1.0.0 entry: features added (`Apple.discover` polymorphic, escape blocks, CF auto-ARC, structured concurrency, ObjC class method), breaking changes (none — all additive), migration notes. |
| **API stability commitment** | `lib/apple_sdk_mac.rb` top docstring locks `Apple.discover` form list as v1.0 stable surface; SemVer policy stated in README. |

## 10. Open questions (none expected at impl time)

If any of the following surfaces during implementation, halt and bring
back to spec review:

- An Apple framework API that legitimately requires a 10th pillar
  (e.g. a runtime concept not absorbable by the existing 9). Spec
  amendment required.
- A symbol whose kind is unrepresentable by the catalog after T14.
  Spec amendment required.
- A latency / memory budget unreachable on macOS 26 hardware.
  Re-baseline § 9, do not ship.

---

End of spec. Implementation begins at T0; T0 commit is already
in-flight in the working tree.

---

## Supersede notice (2026-05-06)

§ 3.2 "polymorphic single entry" 章は、後続 spec
[`2026-05-06-polymorphic-discover-end-to-end.md`](2026-05-06-polymorphic-discover-end-to-end.md)
に supersede された。本 spec の他章（§1, §2, §4, §5, §6, §9）は引き
続き有効。実装は後続 spec の § 5 TDD 順序 (T40-T58) に従う。
