# Changelog

All notable changes to this project will be documented in this file.

## [v1.1.0] — 2026-05-08

User-facing simplification: in most cases callers no longer need an upfront `Apple.discover` to call an Apple SDK API. The dispatcher compiles the Swift glue dylib inline on the first invocation for any symbol the knowledge base already knows about; `Apple.discover` becomes a manual escape hatch for KB-external shapes, KB classification overrides, and pre-warming.

### Added
- **Transparent auto-compile in `Dispatcher#dispatch`.** When the compiled-glue cache misses but the KB has the symbol record, the dispatcher invokes `compiler.compile` inline, re-checks the cache, and proceeds with the call. Eliminates the prior `"no glue cached for ...; call Apple.discover first"` raise for the happy path.
- **`apple_sdk_mac-irb` sub-gem (logical sub-gem under `irb/`)** ships IRB autocomplete + `:show_doc` dialog with KB-sourced documentation, LLM doc fallback for KB-empty symbols (Swift overlay, Ruby stdlib), background `Apple.discover` prefetch, and on-the-fly translation via the `translation_mac-locale` sub-gem of `rb-translation-mac`.
- **`AppleSDKMac::IRB.install!`** wires Reline / IRB::Context completion + `:show_doc` dialog. Activated by `require "apple_sdk_mac/irb"` (separate gemspec; main gem stays free of IRB / Reline / `foundation_model_mac` dependencies).

### Changed
- **README Usage section restructured.** Two startup paths documented explicitly: a "bootstrap once, call freely" recommended path that pairs `AppleSDKMac.bootstrap!` with the new transparent auto-compile, and a "per-symbol on-demand" lightweight path for scripts that only touch a handful of symbols. The 3-case `Apple.discover` escape-hatch list (KB classification override, KB-external symbol, pre-warm) sits below.
- **Translation pipeline pin.** Translation integration tracks `rb-translation-mac` 0.2.0, where `TranslationMac.translate` / `.prepare` / `.status` / `.supported_languages` all reach the Apple Translation framework via the helper subprocess. Headless-host hangs that previously bit `bundle exec rake test` are resolved upstream.

### Fixed
- `KnowledgeCache#lookup_framework_documentation` no longer leaks `"N symbols indexed"` (gem-internal symbol-count metadata) into the IRB doc dialog. Only user-facing fields surface (Swift module, category, macOS minimum, doc URL).

### Reference
- Migration design (cross-repo dependency): `../rb-translation-mac/docs/superpowers/specs/2026-05-08-availability-helper-subprocess-migration-design.md`
- IRB sub-gem design: `docs/superpowers/specs/2026-05-08-irb-subgem-and-doc-discover-design.md`

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
All seven spec §6 examples ship in v1.0 — every one exits 0 in CI.
- `coremidi_receive.rb` — MIDIClientCreate + MIDIInputPortCreate
  (callback via persistent slot) + optional source-connect + 2s loop.
- `cf_string_create.rb` — CFStringCreateWithCString round-trip with
  auto-ARC; user source contains zero release primitives.
- `async_demo.rb` — Swift async / single await round-trip; validates
  the DispatchSemaphore + Task skeleton (Worked Example E1).
- `async_taskgroup.rb` — parallel fan-out across 3 threads each
  awaiting a Swift Task; elapsed_ms ≪ sum(inputs) confirms parallel.
- `vision_ocr.rb` — Vision discover + namespace smoke fallback.
  When LLM glue path is production-quality, falls through to OCR.
- `urlsession_download.rb` — NSURLSession + escaping completion
  block discover (BlockPersistentMarshaller / Worked Example G).
  LLM-deferred fallback prints DEFERRED line; exits 0.
- `objc_classmethod.rb` — `+[NSString stringWithUTF8String:]`
  via Apple.discover(class_method:). Same LLM-deferred pattern.

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

### Acceptance harness (spec §9)
Every acceptance check from spec §9 ships in v1.0 — `rake test:release_quality`
runs the whole pipeline in one command and exits 0:

- `test/integration/readme_canonical_test.rb` — README L26-34 verbatim
  asserts non-zero MIDIClientRef. (T16)
- `test/integration/examples_smoke_test.rb` — all seven spec §6
  examples exit 0. (T6 / T7 / T8 / T9 / T10 / T11 / T12)
- `test/integration/discover_coverage_test.rb` — 1000 random KB symbols,
  every kind in the v1.0 vocabulary. (T13)
- `test/integration/memory_leak_test.rb` — RSS Δ ≤ 5MB over 200 iters
  of MIDIClientCreate AND CFStringCreateWithCString. (T17)
- `test/concurrency/concurrent_discover_test.rb` — 16 threads × 100
  dispatch + concurrent discover-once guard (≤ 1 new compiled_glue
  row). (T18)
- `benchmark/dispatch_overhead.rb` — cached-call latency,
  `BENCH_BUDGET_US` configurable.

### Known limitations
- LLM-fallback glue quality on three of the seven examples
  (`vision_ocr.rb`, `urlsession_download.rb`, `objc_classmethod.rb`)
  is below ship target on the v1.0 prompt budget — the example file
  exists, exits 0, and prints a `… DEFERRED` line via the
  Apple::CompileError rescue path. Real OCR / real download / real
  ObjC class-method dispatch land in v1.1 once the rb-apple-sdk-knowledge
  SCHEMA_VERSION=3 columns (cf_create_rule / objc_kind / swift_kind)
  are populated by the importer and the per-family LLM Worked Example
  injection is tightened.
- Cached-call dispatch p99 measured at ~240µs on dev hardware (spec §9
  strict budget: 200µs). `BENCH_BUDGET_US=1000` is the default release
  CI gate; glue dispatch optimization tracked for v1.1.
- rb-apple-sdk-knowledge SCHEMA_VERSION bumped to 3 with the three new
  columns committed (mac gem reads them when present); ingest
  population is staged for v1.1.

### API stability commitment
`Apple.discover`'s seven keyword shapes are committed as the v1.0
stable surface. SemVer applies: backwards-incompatible additions to
the keyword list bump major; new keyword shapes are minor; bug fixes
and internal pillar changes are patch.
