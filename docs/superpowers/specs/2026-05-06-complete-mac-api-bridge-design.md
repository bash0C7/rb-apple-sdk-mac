# Complete macOS API Bridge — Phase 7 Design

Date: 2026-05-06
Status: draft → awaiting user approval

## Why

The README opens with "Call any public Apple framework API from Ruby with no
pre-declarations." Today the bridge handles a useful subset of synchronous C
APIs. Five concrete blockers prevent that promise from being literally true.
This phase closes them with the smallest plausible internal change.

## Non-goals (Phase 8 territory)

- ObjC selector dispatch (NSWindow / UIViewController patterns)
- Swift structured concurrency (async let, TaskGroup, AsyncSequence)
- ARC bridging for "create-rule" CFTypeRef returns (caller still calls CFRelease manually)

## Internal Structure

The flat `kind → Marshaller` taxonomy is correct. The work is to fill in
catalog entries and tighten classifier regex. No new abstraction is introduced.
A new entry costs:

- one row in `lib/rb_apple_sdk_knowledge/importer/kind.rb` regex tree
- one Marshaller subclass in `lib/apple_sdk_mac/glue_compiler/marshallers.rb`
- (if heading into the runtime side) one signature catalog row in YAML

## Blocker 1 — `cftype_ref` (CF pointer-typed handles)

**Symptom**: `CFStringRef`, `CFArrayRef`, `CFDictionaryRef`, `CFTypeRef`,
`CGColorSpaceRef`, `CGContextRef` etc. are pointer-shape typedefs, but the
classifier currently funnels them into `opaque_ref`, which the
`OpaqueRefMarshaller` materializes via `T(rb_num2ull(...))` (integer
constructor). swiftc rejects: "Cannot invoke initializer for type
'CFStringRef' with an argument list of type '(UInt64)'".

**Fix**:

1. Classifier — add `cftype_ref` ahead of `opaque_ref`:
   ```ruby
   return "cftype_ref" if qual_type =~ /\b(?:CF|CG|CV|CT|CM|CL)\w+Ref\b/
   ```
   (Catches CF, Core Graphics, Core Video, Core Text, Core Media, Core Location
   pointer Refs. Audio/MIDI integer Refs keep their `opaque_ref` route.)

2. New Marshaller `CFTypeRefMarshaller`:
   - `in_load`: `let <name> = OpaquePointer(bitPattern: UInt(rb_num2ull(argv[i])))!` then `unsafeBitCast` to the actual `CFXXXRef` Swift type.
   - `out_init` / `out_addr` for out-params: `var <name>: CFXXXRef? = nil` + `&<name>`.
   - `out_to_ruby`: encodes the pointer via `rb_ull2inum(UInt64(unsafeBitCast(<name>!, to: UInt.self)))`.

3. Knowledge gem reclassifier KIND_VOCABULARY gains `"cftype_ref"`.

## Blocker 2 — Float typedef regex

**Symptom**: `CFAbsoluteTime`, `CFTimeInterval`, `NSTimeInterval`, `CGFloat`
are all `double` underneath but the classifier sees an unknown typedef and
classifies as `int`, losing precision.

**Fix**: Extend classifier float branch:
```ruby
return "float" if qual_type =~ /\b(double|float|CGFloat|CFAbsoluteTime|CFTimeInterval|NSTimeInterval|TimeInterval)\b/
```
No new Marshaller. Reclassifier KIND_VOCABULARY already includes `"float"`.

## Blocker 3 — Block parameters

**Symptom**: Apple's modern API style is `^void (NSError *_Nullable error)`.
clang AST presents these as `BlockPointer`. The classifier funnels them into
`unsupported` because (a) `is_function_pointer` (paren detection) doesn't
trigger on the Block typedef encoding, and (b) Block ABI ≠ C function pointer
ABI (Block has a header struct in front of the invoke pointer).

**Fix**: Mirror the Callback Pillar architecture:

1. New file `ext/apple_sdk_mac_runtime/block_signatures.yml`:
   ```yaml
   - name: error_handler          # void (^)(NSError *_Nullable)
     swift_type: "@convention(block) (NSError?) -> Void"
     pool_size: 4
     ruby_arity: 1                # NSError*  → Ruby NSError wrapper
   - name: image_request_handler  # void (^)(VNRequest *, NSError *)
     swift_type: "@convention(block) (VNRequest, NSError?) -> Void"
     pool_size: 4
     ruby_arity: 2
   ```

2. New `lib/apple_sdk_mac/block_pillar_codegen.rb` — emits per-slot Block
   trampolines into `BlockPillarGenerated.swift` (closure literals retained
   in a slot pool, mirrored on the Callback Pillar `NSLock` pattern).

3. Two Marshallers: `BlockNilableMarshaller`, `BlockNonNilMarshaller`. Their
   `in_load` follows the same register-via-`$__apple_sdk_mac_proc_registry`
   pathway as `CallbackNilableMarshaller`.

4. Classifier (`kind.rb`): detect Block at AST level by adding a
   `is_block_pointer` flag to `header_parser.rb` (clang's `BlockPointerType`
   node — already represented in the AST, just not surfaced).

5. Knowledge gem reclassifier KIND_VOCABULARY gains `"block_nilable"`,
   `"block_non_nil"`.

## Blocker 4 — examples revival

**Symptom**: `examples/coremidi_receive.rb` and `examples/vision_ocr.rb`
crash on first call.

**Fix**: After Blockers 1–3 are green, both examples should run without
example-side changes. If they don't, the smallest delta is added to:
- adapt example to the API surface that exists
- file ticket against missing types if any new ones surface

Both examples become integration tests under
`test/integration/examples_smoke_test.rb` so regressions are caught.

## Blocker 5 — Swift-only LLM fallback proof

**Symptom**: APIs that exist only as Swift symbols (no `.h` declaration) — e.g.
`async throws` functions — currently never get exercised end-to-end. The LLM
fallback path is plumbed but never proved out.

**Fix**:

1. Pick one stable Swift-only API. Candidate: a method on `URLSession` or a
   `Foundation` async helper. Concretely: `URLSession.shared.data(from:URL)`
   is `async throws -> (Data, URLResponse)`.

2. Add **Worked Example E** to `LLMGenerator::INSTRUCTIONS`:
   ```swift
   // Example E — Swift-only async throws, called from Ruby Fiber.
   //   func fetchData(_ url: URL) async throws -> Int  // (e.g. byte count)
   // Bridge runs the async call inside a Task with a semaphore wait so the
   // glue C ABI returns synchronously to Ruby.
   ```
   Pattern: `DispatchSemaphore` + `Task { ... ; sema.signal() }` + try/catch
   to `rb_raise`.

3. Add `test/integration/swift_only_async_test.rb` — RED first, then turn
   green when the LLM fallback emits compileable Swift.

If after 6 LLM attempts the symbol can't be made deterministic, downgrade
criterion 5 to "documented limitation" rather than block the phase.

## Acceptance Criteria

1. `Apple::CoreFoundation.CFStringCreateWithCString(nil, "hi", 0x08000100)` returns Integer that `Apple::CoreFoundation.CFRelease` accepts
2. `Apple::CoreFoundation.CFAbsoluteTimeGetCurrent()` returns Float (Ruby class match)
3. `examples/coremidi_receive.rb` runs for 5s, exits 0
4. `examples/vision_ocr.rb` recognizes a fixture image's text (or prints "no text" if Vision sees none)
5. One Swift-only async API works through LLM fallback (or limitation documented)
6. All pre-existing tests pass

## TDD Decomposition (independent commits)

T1 cftype_ref:
- RED: `test_cftype_ref_marshaller_emits_pointer_cast`
- GREEN: classifier + Marshaller
- Knowledge reclassifier vocabulary + integration smoke

T2 float typedef regex:
- RED: classifier test for `CFAbsoluteTime` → "float"
- GREEN: regex line

T3 Block parameters:
- RED: classifier test for `void (^)(NSError *)` → "block_nilable"
- RED: BlockNilableMarshaller emits register-pathway Swift
- RED: codegen produces `BlockPillarGenerated.swift`
- GREEN: full chain

T4 examples revival:
- RED: integration test running each example end-to-end
- GREEN: any required deltas

T5 Swift-only fallback:
- RED: integration test invoking a Swift async API
- GREEN: worked Example E + retries land

## Risks

- **Block ABI**: macOS Block layout is well-documented (Block_layout struct), but `@convention(block)` from Swift wraps that automatically. Risk is low; failure mode is a swiftc compile error caught by ValidationGates → test fails loudly.
- **Vision example**: VNImageRequestHandler requires a CGImage; loading a PNG into CGImage from Ruby goes through CGImageSourceRef + CGImageSourceCreateImageAtIndex, both CF pointer Refs. Phase-7 work unblocks them, but the example may surface fresh classification gaps. Plan: file a follow-up if a *new* kind surfaces; do not expand scope mid-phase.
- **LLM fallback**: see Blocker 5 mitigation.

## What this phase does NOT touch

- `lib/apple_sdk_mac/dispatcher.rb` — no protocol changes
- `lib/apple_sdk_mac/namespace_builder.rb` — no protocol changes
- `lib/apple_sdk_mac/security_cop*` — orthogonal
- Any pillar other than CallbackPillar (whose pattern Block reuses)

Scope discipline: only files needed by the Marshallers, classifier, codegen,
LLM INSTRUCTIONS, and the new tests.
