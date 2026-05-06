# Changelog

All notable changes to this project will be documented in this file.

## [v1.0.0] — 2026-05-06 — Phase 7 / release-quality

### Added
- **`Apple.discover` polymorphic single entry** — seven keyword shapes
  routed through one method:
  - `symbol:` — C function (the README canonical form)
  - `class_method:` — ObjC class method (with `klass:`)
  - `selector:` — ObjC instance method (with `klass:`)
  - `swift_func:` — Swift function (top-level / static)
  - `swift_initializer:` — Swift initializer (with `klass:`)
  - `swift_property:` — Swift property (with `klass:`)
  - `type_args:` — Swift generic resolution (combined with `swift_func:`)
- **CFTypeRef auto-ARC** via the runtime ARC pillar's
  `runtime_arc_box_cftype` entry point + `BoxedCFType` Swift class.
  CF Create-rule returns are wrapped at the bridge boundary; user
  code never calls `CFRelease`.
- **Block marshallers** — `BlockNilableMarshaller` (noescape, inline
  `@convention(block)`) and `BlockPersistentMarshaller` (escaping,
  routed through the CallbackPillar persistent slot table). Lifetime
  is AST-tag-driven.
- **Persistent block slot table** in `CallbackPillar` plus
  `BoxedBlockHandle` for Ruby-GC-tied auto-unregister.
- **Async / structured concurrency worked examples** E1-E4
  (single `await` / `TaskGroup` / `async let` / `MainActor.run`)
  encoded in the LLM generator's instructions.
- **ObjC method dispatch worked examples** F1 (alloc/init), F2
  (pure class method), G (ObjC + completion block).
- **ValidationGates extensions** — async-shape, persistent-block-shape,
  autoarc-shape, objc-bridge-shape gates reject malformed glue
  before swiftc.
- **`Apple.diagnostics`** — JSON dump of cache stats, recent LLM
  attempts (last 16), validation failures (last 16), and pillar
  runtime stats. Sufficient for issue reproduction.
- **`Apple::Error` hierarchy** — `Apple::DiscoveryError`,
  `Apple::CompileError`, `Apple::CallError`. Bridge aliases under
  `AppleSDKMac::*` keep `rescue AppleSDKMac::Error` working.
- **CompiledGlueCache schema_version invalidation** — pre-bump rows
  evicted automatically when the template HEADER, marshaller emit, or
  validation gate set changes.
- **`benchmark/dispatch_overhead.rb`** — cached-call latency measurement
  with `BENCH_BUDGET_US` env override (spec target: p99 ≤ 200µs).
- **`test/integration/readme_canonical_test.rb`** — pins the README
  L26-34 snippet as the central acceptance gate; runs verbatim under
  RUBY_BOX=1 and asserts non-zero MIDIClientRef.

### Examples (run under `RUBY_BOX=1 bundle exec ruby examples/<name>`)
- `cf_string_create.rb` — CFStringCreateWithCString round-trip with
  auto-ARC; user source contains zero release primitives.

### Fixed
- `CFTypeRefMarshaller` now Qnil-aware: NULL allocators / nullable CF
  inputs no longer SIGTRAP. Force-unwrap removed.
- `IntMarshaller.call_arg` narrows Int64 → ctype via
  `truncatingIfNeeded:` so CFStringEncoding / OSStatus / int / unsigned
  variants compile under swiftc 6.
- `ref_type` strips trailing `Ref` (Swift 6 renamed CFAllocatorRef →
  CFAllocator etc.).
- `template_generator` `return_kind` no longer maps CFStringRef /
  NSString \* to "string" — those are CF / ObjC opaque types and need
  cftype_ref / opaque_ref handling.
- `effective_return_kind` upgrades CF\*Create / CF\*Copy returns to
  `cftype_ref_autoarc` via the spec §5 naming-prefix heuristic when
  the clang AST attribute is missing.
- `Apple::Error` hierarchy survives Ruby::Box bootstrap — class objects
  live under AppleSDKMac, then are aliased into the Apple Box post-bootstrap.
- LLMGenerator uses **kind-family-scoped sessions** (one
  representative example per family) to fit the Foundation Models
  4096-token context window. The full INSTRUCTIONS bundle is preserved
  for prose / contract tests.

### Architecture
- 9-pillar count locked. Phase 7 *extends* Callback (persistent block
  slots) and ARC (BoxedCFType) pillars only — no new pillar.
- KnowledgeCache gains a transient lookup tier; `Apple.discover`
  registers synthesized symbol records there for non-C shapes.

### Known limitations / deferred to v1.1
- `examples/objc_classmethod.rb` is deferred — LLM output for
  `+stringWithUTF8String:` exhausts validation retries on the current
  prompt budget. Requires the rb-apple-sdk-knowledge SCHEMA_VERSION=3
  migration (cf_create_rule / objc_kind / swift_kind columns) plus
  per-call worked-example injection.
- Cached-call dispatch p99 measured at ~307µs on dev hardware
  (spec §9 strict budget: 200µs). Configurable via `BENCH_BUDGET_US`;
  glue dispatch optimization tracked for v1.1.
- `examples/coremidi_receive.rb`, `examples/vision_ocr.rb`,
  `examples/async_demo.rb`, `examples/urlsession_download.rb`,
  `examples/async_taskgroup.rb` — present in spec §6 but only
  `cf_string_create.rb` ships in v1.0 alongside the canonical
  CoreMIDI snippet.
- T13 `discover_coverage_test.rb`, T17 `memory_leak_test.rb`,
  T18 `concurrent_discover_test.rb` — release-quality acceptance
  harness deferred. Current rake test (146 tests, 0 failures, 1
  known-flaky CoreMIDI timing case) covers the unit + integration
  surface.

### API stability commitment
`Apple.discover`'s seven keyword shapes are committed as the v1.0
stable surface. SemVer applies: backwards-incompatible additions to
the keyword list bump major; new keyword shapes are minor; bug fixes
and internal pillar changes are patch.
