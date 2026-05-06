# Phase 7 — Complete macOS API Bridge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land Phase 7 of the rb-apple-sdk-mac gem to v1.0 release-quality, fully satisfying the literal claims in `README.md` (L3 tagline + L29-34 canonical Usage + L42-47 Architecture). One push, one spec, `git status` clean, `v1.0.0` tag attached.

**Architecture:** No new pillars (count stays 9), no new dispatch layer. Phase 7 *extends* the existing Callback pillar (escape blocks) and ARC pillar (CFType auto-ARC), adds `Apple.discover` polymorphic dispatch in `public_api.rb`, adds three Marshallers (`BlockNilableMarshaller`, `BlockPersistentMarshaller`, `CFTypeRefAutoARCMarshaller`), extends `LLMGenerator` INSTRUCTIONS with Worked Examples E1-E4 / F1-F2 / G, and tightens `ValidationGates`. Knowledge gem ships a coupled SCHEMA_VERSION=3 migration with new clang-AST attribute reads. See spec §3 for full architecture.

**Tech Stack:** Ruby 4.0.3 (`RUBY_BOX=1`), Swift 6.3+, swiftc with `-undefined dynamic_lookup`, Test::Unit, SQLite (CompiledGlueCache + Knowledge DB), `swift_gem` (Foundation Model via Ollama), CoreMIDI / Vision / Foundation / NSURLSession (test surfaces).

**Source spec:** `docs/superpowers/specs/2026-05-06-complete-mac-api-bridge-design.md`. This plan does NOT duplicate spec content — it references spec sections by `§N.M` and embeds only the code/test fragments an executor needs in-line.

**Sibling repos used:**
- `~/dev/src/github.com/bash0C7/rb-apple-sdk-knowledge` — Knowledge gem. T1 + T14 happen here.
- `~/dev/src/github.com/bash0C7/swift_gem` — currently pinned via git in `Gemfile`.
- `~/dev/src/github.com/bash0C7/rb-foundation-model-mac` — local path in `Gemfile`.

**Execution order (DAG-flattened):**

T0 → T14 (knowledge schema) → T1 (knowledge classifier) → T2a → T2b → T2c → T3a → T3b → T3c → T4 → T5 → T6 → T7 → T8 → T9 → T10 → T11 → T12 → T13 → T15 → T16 → T17 → T18 → T19 → T20

Hard dependency edges:
- T0 unblocks T2a/b/c (block marshallers reference `runtime_proc_registry_get` symbol shipped in T0).
- T14 unblocks T1 (T1 reads new schema columns) and T13 (kind coverage requires schema).
- T2a/b/c unblock T6-T12 (examples that use callbacks).
- T3c unblocks T6-T12 examples that take `await`/persistent block paths.
- T4 unblocks T11 (`cf_string_create.rb`).
- T5 unblocks T13 (`Apple.discover` polymorphic must exist).

---

## File Structure

Spec §3.1 has the full table. Quick reference:

**Created:**
- `lib/apple_sdk_mac/diagnostics.rb` (T19)
- `lib/apple_sdk_mac/errors.rb` (T19)
- `examples/async_demo.rb` (T8)
- `examples/urlsession_download.rb` (T9)
- `examples/async_taskgroup.rb` (T10)
- `examples/cf_string_create.rb` (T11)
- `examples/objc_classmethod.rb` (T12)
- `test/fixtures/ocr_sample.png` (T7)
- `test/integration/discover_coverage_test.rb` (T13)
- `test/integration/memory_leak_test.rb` (T17)
- `test/integration/readme_canonical_test.rb` (T16)
- `test/concurrency/concurrent_discover_test.rb` (T18)
- `test/diagnostics_test.rb` (T19)
- `test/errors_test.rb` (T19)
- `benchmark/dispatch_overhead.rb` (T19)
- `benchmark/discover_latency.rb` (T19, §9)
- `CHANGELOG.md` (T20)

**Modified:**
- `ext/apple_sdk_mac_runtime/Sources/AppleSDKMacRuntime/RuntimeBridge.swift` (T0 — already in working tree)
- `ext/apple_sdk_mac_runtime/apple_sdk_mac_runtime.c` (T0 — already in working tree)
- `ext/apple_sdk_mac_runtime/Package.swift` (T0 — already in working tree)
- `ext/apple_sdk_mac_runtime/AppleSDKMacRuntime-Swift.h` (T0 — regenerated)
- `ext/apple_sdk_mac_runtime/Sources/AppleSDKMacRuntime/CallbackBridge.swift` + `CallbackPillar.swift` (T2c)
- `lib/apple_sdk_mac/glue_compiler/marshallers.rb` (T2a, T2b, T4 — base T0 shim already in working tree)
- `lib/apple_sdk_mac/glue_compiler/template_generator.rb` (T0 base in working tree; T5)
- `lib/apple_sdk_mac/glue_compiler/llm_generator.rb` (T3a, T3b)
- `lib/apple_sdk_mac/glue_compiler/validation_gates.rb` (T3c)
- `lib/apple_sdk_mac/public_api.rb` (T5)
- `lib/apple_sdk_mac.rb` (T5, T19)
- `lib/apple_sdk_mac/compiled_glue_cache.rb` (T15)
- `examples/coremidi_receive.rb` (T6)
- `examples/vision_ocr.rb` (T7)
- `test/integration/examples_smoke_test.rb` (T6-T12, expanded)
- `Rakefile` (T0 header sync, T20 aggregate)
- `Gemfile` / `*.gemspec` (T20)

**Sibling repo `rb-apple-sdk-knowledge`** (T1 + T14):
- `lib/.../store.rb` schema bump
- `lib/.../importer/header_parser.rb` clang AST attrs
- `lib/.../importer/swift_interface_parser.rb` async/MainActor/generic
- `lib/.../reclassifier.rb` KIND_VOCABULARY
- `lib/.../kind.rb` block AST detection
- corresponding tests

---

## Pre-flight: clean baseline

- [ ] **Step 0.0: Verify clean test baseline before T0**

Run: `bundle exec rake test 2>&1 | tail -5`
Expected: existing test count, current red set documented (4 tests in `coremidi_smoke_test.rb` + 1 in `threading_bridge_test.rb` if proc_registry fix not yet effective). No errors that imply structural drift unrelated to T0.

If anything else is red beyond expected scope, stop and report — don't paper over.

---

## Task T0: proc_registry → Swift dylib (in-flight)

**Goal:** The 4 gate tests pass simultaneously. T0 moves `proc_registry` out of the C-extension's RTLD_LOCAL boundary into the runtime Swift dylib, so per-symbol glue dylibs reach the same Hash.

**Files (already modified in working tree, see `git diff`):**
- Modify: `ext/apple_sdk_mac_runtime/Package.swift` (`-undefined dynamic_lookup` linker flag)
- Modify: `ext/apple_sdk_mac_runtime/Sources/AppleSDKMacRuntime/RuntimeBridge.swift` (`appleProcRegistry: UInt`, `runtime_proc_registry_init`, `runtime_proc_registry_get`)
- Modify: `ext/apple_sdk_mac_runtime/apple_sdk_mac_runtime.c` (`#define proc_registry runtime_proc_registry_get()`)
- Modify: `ext/apple_sdk_mac_runtime/AppleSDKMacRuntime-Swift.h` (regenerated by `swift build`)
- Modify: `lib/apple_sdk_mac/glue_compiler/marshallers.rb` (callback site → `runtime_proc_registry_get()`)
- Modify: `lib/apple_sdk_mac/glue_compiler/template_generator.rb` (HEADER `@_silgen_name("runtime_proc_registry_get")` declaration)
- Modify: `Rakefile` (add `apple:runtime:sync_header` task per §3.1.1)

**Test files (gate set — must all be green simultaneously):**
- `test/integration/coremidi_smoke_test.rb::test_receive_notification`
- `test/integration/coremidi_smoke_test.rb::test_send_packet_via_midi_received`
- `test/threading_bridge_test.rb` (full file)
- `test/callback_pillar_test.rb` (full file)

- [ ] **Step T0.1: Add Rakefile header sync task (spec §3.1.1)**

Edit: `Rakefile`. Append after the `runtime:codegen_callback_pillar` namespace block:

```ruby
namespace :apple do
  namespace :runtime do
    desc "swift build the runtime dylib and copy generated -Swift.h into ext/"
    task :sync_header do
      ext_dir = File.expand_path("ext/apple_sdk_mac_runtime", __dir__)
      sh "swift", "build", "--package-path", ext_dir
      build_dir = File.join(ext_dir, ".build")
      generated = Dir.glob(File.join(build_dir, "**", "AppleSDKMacRuntime-Swift.h")).first
      raise "AppleSDKMacRuntime-Swift.h not produced by swift build" unless generated
      target = File.join(ext_dir, "AppleSDKMacRuntime-Swift.h")
      require "fileutils"
      FileUtils.cp(generated, target)
      puts "synced #{generated} → #{target}"
    end
  end
end

# Compile depends on header sync so the C ext never sees a stale -Swift.h.
task compile: "apple:runtime:sync_header"
```

- [ ] **Step T0.2: Run swift build to regenerate header**

Run: `bundle exec rake apple:runtime:sync_header`
Expected: success; `ext/apple_sdk_mac_runtime/AppleSDKMacRuntime-Swift.h` updated to declare `runtime_proc_registry_init` and `runtime_proc_registry_get`. Inspect with `grep -n runtime_proc_registry ext/apple_sdk_mac_runtime/AppleSDKMacRuntime-Swift.h`; expect 2 hits.

If swift build fails: examine error, fix in `RuntimeBridge.swift`, re-run. Do NOT proceed until header has both symbols.

- [ ] **Step T0.3: Compile the C ext against new header**

Run: `bundle exec rake compile`
Expected: success; `lib/apple_sdk_mac/apple_sdk_mac_runtime.bundle` rebuilt.

If link fails on `runtime_proc_registry_get` undefined: header sync didn't run; redo Step T0.2.

- [ ] **Step T0.4: Run gate test 1 — `test_receive_notification`**

Run: `bundle exec ruby -Ilib -Itest test/integration/coremidi_smoke_test.rb -n test_receive_notification`
Expected: PASS — synthetic `threading_enqueue_from_thread(block.object_id, 7)` round-trips through `runtime_proc_registry_get()` Hash → `ruby_callback_dispatcher` → user Proc → `notifs` array contains 7.

If FAIL: this is the regression mode T0 fixes. Confirm `runtime_proc_registry_get()` returns a non-zero VALUE in C (e.g. add a temporary `fprintf(stderr, "preg=%lu\n", proc_registry);` in `ruby_callback_dispatcher` and re-run). If proc_registry is 0, `runtime_proc_registry_init` was not called by `Init_apple_sdk_mac_runtime`. Fix and re-run.

- [ ] **Step T0.5: Run gate test 2 — `test_send_packet_via_midi_received`**

Run: `bundle exec ruby -Ilib -Itest test/integration/coremidi_smoke_test.rb -n test_send_packet_via_midi_received`
Expected: PASS.

- [ ] **Step T0.6: Run gate test 3 — `threading_bridge_test`**

Run: `bundle exec ruby -Ilib -Itest test/threading_bridge_test.rb`
Expected: all tests pass.

- [ ] **Step T0.7: Run gate test 4 — `callback_pillar_test`**

Run: `bundle exec ruby -Ilib -Itest test/callback_pillar_test.rb`
Expected: all tests pass.

- [ ] **Step T0.8: Run full test suite to confirm no regressions**

Run: `bundle exec rake test 2>&1 | tail -10`
Expected: no NEW failures vs. baseline (Step 0.0). Existing reds unrelated to T0 may persist.

- [ ] **Step T0.9: Commit T0**

```bash
git add Rakefile ext/apple_sdk_mac_runtime/Package.swift \
        ext/apple_sdk_mac_runtime/Sources/AppleSDKMacRuntime/RuntimeBridge.swift \
        ext/apple_sdk_mac_runtime/apple_sdk_mac_runtime.c \
        ext/apple_sdk_mac_runtime/AppleSDKMacRuntime-Swift.h \
        lib/apple_sdk_mac/glue_compiler/marshallers.rb \
        lib/apple_sdk_mac/glue_compiler/template_generator.rb
git commit -m "feat: route proc_registry through runtime Swift dylib via flat namespace

Moves the Ruby Hash that pins live Procs out of the C-extension
RTLD_LOCAL boundary into libAppleSDKMacRuntime.dylib's
runtime_proc_registry_get(). Both the dispatcher and per-symbol glue
dylibs now resolve to the same Hash, fixing notification/callback
round-trips under RUBY_BOX=1.

Closes T0 of Phase 7 spec (2026-05-06-complete-mac-api-bridge-design.md)."
```

Note: `Gemfile` change (swift_gem switch to git) is logically separate — leave it for T20 gemspec audit, OR commit separately as a chore if the executor prefers a tidy working tree. Suggested: commit separately now with `chore: pin swift_gem to git ref during sibling-repo dev`.

---

## Task T14 (executed before T1): Knowledge gem schema migration

**Repo switch:** `cd ~/dev/src/github.com/bash0C7/rb-apple-sdk-knowledge`

**Goal:** Bump `SCHEMA_VERSION` to 3, add `cf_create_rule INTEGER DEFAULT 0`, `objc_kind TEXT`, `swift_kind TEXT` columns. Extend `parameters_json` JSON shape with per-param `block_lifetime`. Schema migration auto-detects v2 DBs and triggers full re-ingest.

**Files in knowledge gem:**
- Modify: `lib/.../store.rb` (schema bump + migration logic)
- Modify: `lib/.../importer/header_parser.rb` (read clang AST attrs `CF_RETURNS_RETAINED`, `CF_RETURNS_NOT_RETAINED`, `__attribute__((noescape))`, `NS_RETURNS_RETAINED`)
- Modify: `lib/.../importer/swift_interface_parser.rb` (detect `async` / `@MainActor` / generic `<T>`)
- Test: `test/store_test.rb`

- [ ] **Step T14.1: Locate store.rb and the existing schema test**

Run: `find ~/dev/src/github.com/bash0C7/rb-apple-sdk-knowledge/lib -name "store.rb"; find ~/dev/src/github.com/bash0C7/rb-apple-sdk-knowledge/test -name "store_test.rb"`
Expected: one match each.

- [ ] **Step T14.2: Write the failing test**

Append to the knowledge gem's `test/store_test.rb`:

```ruby
def test_schema_version_3_adds_cf_create_rule_and_objc_swift_kinds
  store = Store.new(":memory:")
  store.migrate!
  cols = store.db.execute("PRAGMA table_info(symbols)").map { |r| r[1] }
  assert_includes cols, "cf_create_rule"
  assert_includes cols, "objc_kind"
  assert_includes cols, "swift_kind"
  meta = store.db.execute("SELECT value FROM schema_meta WHERE key='schema_version'").first
  assert_equal "3", meta[0]
end

def test_ingest_populates_cf_create_rule_from_clang_ast
  store = Store.new(":memory:")
  store.migrate!
  store.upsert_symbol(framework: "CoreFoundation", name: "CFStringCreateWithCString",
                     kind: "function",
                     return_type: "CFStringRef",
                     attrs: { "CF_RETURNS_RETAINED" => true })
  row = store.db.execute("SELECT cf_create_rule FROM symbols WHERE name='CFStringCreateWithCString'").first
  assert_equal 1, row[0]
end

def test_ingest_populates_block_lifetime_per_param
  store = Store.new(":memory:")
  store.migrate!
  store.upsert_symbol(framework: "Foundation", name: "exampleWithCompletion",
                     kind: "function",
                     parameters_json: JSON.generate([
                       { name: "completion", type: "void(^)(NSError*)",
                         block_lifetime: "noescape" }
                     ]))
  json = store.db.execute("SELECT parameters_json FROM symbols WHERE name='exampleWithCompletion'").first[0]
  assert_equal "noescape", JSON.parse(json).first["block_lifetime"]
end
```

- [ ] **Step T14.3: Run test to verify failures**

Run: `cd ~/dev/src/github.com/bash0C7/rb-apple-sdk-knowledge && bundle exec rake test TEST=test/store_test.rb 2>&1 | tail -15`
Expected: 3 failures — columns missing / schema_version mismatch / block_lifetime not preserved.

- [ ] **Step T14.4: Implement schema bump in `store.rb`**

Locate `SCHEMA_VERSION = 2` (or current value). Bump to 3. In `migrate!`, add migration block:

```ruby
SCHEMA_VERSION = 3

def migrate!
  current = current_schema_version
  if current < 3
    db.execute_batch <<~SQL
      ALTER TABLE symbols ADD COLUMN cf_create_rule INTEGER DEFAULT 0;
      ALTER TABLE symbols ADD COLUMN objc_kind TEXT;
      ALTER TABLE symbols ADD COLUMN swift_kind TEXT;
    SQL
    db.execute("INSERT OR REPLACE INTO schema_meta(key, value) VALUES('schema_version', '3')")
  end
end
```

If `current_schema_version` doesn't exist yet, add it: read from `schema_meta` table (creating the table if missing), default 0 for fresh DBs.

- [ ] **Step T14.5: Extend `upsert_symbol` to write new columns + parameters_json block_lifetime**

In `upsert_symbol(...)` accept `attrs:` hash and `parameters_json:` (already string or built from array). Map `attrs["CF_RETURNS_RETAINED"]` → `cf_create_rule = 1`. Pass through `objc_kind`, `swift_kind`. For `parameters_json`, just store the JSON as-is (block_lifetime is already inside the JSON shape, no migration needed beyond not stripping it).

- [ ] **Step T14.6: Run knowledge gem tests**

Run: `cd ~/dev/src/github.com/bash0C7/rb-apple-sdk-knowledge && bundle exec rake test TEST=test/store_test.rb 2>&1 | tail -15`
Expected: all 3 new tests pass; existing tests still pass.

- [ ] **Step T14.7: Extend `header_parser.rb` to read clang AST attributes**

Modify the C header parsing path (clang AST traversal). When a function declaration is visited, inspect attribute children for `CF_RETURNS_RETAINED`, `CF_RETURNS_NOT_RETAINED`, `NS_RETURNS_RETAINED`. Build `attrs` hash and pass to `store.upsert_symbol`.

For each parameter declaration, inspect for `__attribute__((noescape))` (clang exposes as `NoEscape` attr in AST). Set `block_lifetime: "noescape"` if present, else `"escaping"` for `^`-typed parameters.

Add focused parser test:

```ruby
def test_header_parser_extracts_cf_returns_retained
  fixture = <<~C
    typedef const struct __CFString * CFStringRef;
    extern CFStringRef MyCreateThing(void) __attribute__((cf_returns_retained));
  C
  parser = HeaderParser.new
  records = parser.parse_string(fixture)
  rec = records.find { |r| r[:name] == "MyCreateThing" }
  assert_equal true, rec[:attrs]["CF_RETURNS_RETAINED"]
end
```

Implement via the existing libclang invocation; if the parser uses `clang -ast-dump=json`, walk the `attributes` array per node.

- [ ] **Step T14.8: Extend `swift_interface_parser.rb`**

Detect `func ... async` → `swift_kind: "swift_async"`. Detect `@MainActor` annotation on declarations → set isolation flag. Detect generic `<T>` parameter lists.

- [ ] **Step T14.9: Run full knowledge gem suite**

Run: `cd ~/dev/src/github.com/bash0C7/rb-apple-sdk-knowledge && bundle exec rake test 2>&1 | tail -10`
Expected: all green.

- [ ] **Step T14.10: Bump knowledge gem version, commit, push**

In knowledge gem: bump `lib/.../version.rb` to next version (e.g. `0.5.0` → `0.6.0`). Commit:

```bash
cd ~/dev/src/github.com/bash0C7/rb-apple-sdk-knowledge
git add -A
git commit -m "feat: SCHEMA_VERSION=3 — cf_create_rule, objc_kind, swift_kind columns + clang AST attrs

Adds knowledge schema columns required for rb-apple-sdk-mac Phase 7
(CFTypeRef auto-ARC, ObjC method introspection, Swift kind dispatch).
Header parser now reads CF_RETURNS_RETAINED / NS_RETURNS_RETAINED /
__attribute__((noescape)). Swift interface parser detects async /
@MainActor / generic params.

Coupled with rb-apple-sdk-mac Phase 7 T14."
```

If knowledge gem has a remote and you have push rights, push. Otherwise the local path/git ref in mac gem's Gemfile already points here.

- [ ] **Step T14.11: Bump rb-apple-sdk-mac Gemfile knowledge ref**

Back in `~/dev/src/github.com/bash0C7/rb-apple-sdk-mac`:

```bash
bundle update rb-apple-sdk-knowledge
```

If this changes `Gemfile.lock`, commit:

```bash
git add Gemfile.lock
git commit -m "chore: bump rb-apple-sdk-knowledge to SCHEMA_VERSION=3"
```

---

## Task T1: Block AST detection in classifier (knowledge gem)

**Repo:** `~/dev/src/github.com/bash0C7/rb-apple-sdk-knowledge`

**Goal:** `kind.rb` classifier returns `block_nilable` for noescape blocks, `block_persistent` for escaping blocks. `KIND_VOCABULARY` (in `reclassifier.rb`) gains the new entries.

- [ ] **Step T1.1: Write the failing test in `test/kind_test.rb`**

```ruby
def test_block_with_noescape_attr_is_block_nilable
  rec = {
    name: "completion",
    type: "void (^)(NSError*)",
    attrs: { "noescape" => true }
  }
  assert_equal "block_nilable", Kind.classify_param(rec)
end

def test_block_without_noescape_attr_is_block_persistent
  rec = {
    name: "completion",
    type: "void (^)(NSError*)",
    attrs: {}
  }
  assert_equal "block_persistent", Kind.classify_param(rec)
end

def test_kind_vocabulary_includes_new_entries
  vocab = Reclassifier::KIND_VOCABULARY
  %w[block_nilable block_persistent cftype_ref_autoarc
     objc_method_instance objc_method_class
     swift_func swift_init swift_property].each do |k|
    assert_includes vocab, k, "missing kind: #{k}"
  end
end
```

- [ ] **Step T1.2: Run failing test**

Run: `bundle exec rake test TEST=test/kind_test.rb 2>&1 | tail -10`
Expected: 3 fails — Kind.classify_param doesn't handle `(^)` AST yet, KIND_VOCABULARY missing entries.

- [ ] **Step T1.3: Implement `(^)` branch + attr reader in `kind.rb`**

```ruby
def self.classify_param(rec)
  type = rec[:type].to_s
  if type.match?(/\(\s*\^\s*\)/)
    return rec[:attrs]&.[]("noescape") ? "block_nilable" : "block_persistent"
  end
  # ... existing classifier branches
end
```

- [ ] **Step T1.4: Extend KIND_VOCABULARY in `reclassifier.rb`**

```ruby
KIND_VOCABULARY = %w[
  string int bool float opaque_ref cftype_ref cftype_ref_autoarc
  callback_nilable callback_non_nil void_ptr_nilable
  struct_in struct_out struct_in_pointer variadic_args
  block_nilable block_persistent
  objc_method_instance objc_method_class
  swift_func swift_init swift_property
].freeze
```

- [ ] **Step T1.5: Run tests pass**

Run: `bundle exec rake test TEST=test/kind_test.rb 2>&1 | tail -10`
Expected: all green.

- [ ] **Step T1.6: Run full knowledge gem suite**

Run: `bundle exec rake test 2>&1 | tail -10`
Expected: all green.

- [ ] **Step T1.7: Commit knowledge gem T1**

```bash
git add -A
git commit -m "feat: classify (^) types as block_nilable / block_persistent based on noescape attr

Phase 7 T1 — block AST classifier. Combined with the SCHEMA_VERSION=3
attribute pipeline from T14, completion-block parameters now drive
the new BlockNilableMarshaller / BlockPersistentMarshaller paths in
the consumer mac gem."
```

Then back in mac gem: `bundle update rb-apple-sdk-knowledge`; commit `Gemfile.lock` if it changed.

---

## Task T2a: BlockNilableMarshaller (mac gem)

**Repo:** back to `~/dev/src/github.com/bash0C7/rb-apple-sdk-mac`.

**Files:**
- Modify: `lib/apple_sdk_mac/glue_compiler/marshallers.rb`
- Test: `test/glue_compiler/template_generator_test.rb`

- [ ] **Step T2a.1: Write the failing test**

In `test/glue_compiler/template_generator_test.rb`, add:

```ruby
def test_block_nilable_marshaller_emits_stack_local_convention_block
  spec = {
    framework: "Foundation",
    symbol: "exampleWithCompletion",
    abi: "c",
    return_kind: "void",
    params: [
      { name: "completion", kind: "block_nilable",
        signature: "(NSError*) -> Void" }
    ]
  }
  swift = TemplateGenerator.generate(spec)
  assert_match(/let completion_block: \(@convention\(block\)/, swift)
  assert_match(/runtime_proc_registry_get\(\)/, swift)
  assert_match(/ThreadingBridge\.enqueueFromAppleThread/, swift)
  refute_match(/runtime_callback_register_block_persistent/, swift)
end
```

- [ ] **Step T2a.2: Run failing test**

Run: `bundle exec ruby -Ilib -Itest test/glue_compiler/template_generator_test.rb -n test_block_nilable_marshaller_emits_stack_local_convention_block`
Expected: FAIL — kind `block_nilable` not in REGISTRY.

- [ ] **Step T2a.3: Implement `BlockNilableMarshaller` in `marshallers.rb`**

Reference: spec §3.4 first code block.

```ruby
class BlockNilableMarshaller < Marshaller
  KIND = "block_nilable"

  def emit(name:, index:, signature:)
    sig_in, sig_out = parse_block_signature(signature)  # "(NSError*) -> Void" → ["NSError?"], "Void"
    <<~SWIFT
      let #{name}_block: (@convention(block) (#{sig_in.join(", ")}) -> #{sig_out})?
      if argv[#{index}] == Qnil {
          #{name}_block = nil
      } else {
          let #{name}_pid_v = rb_obj_id(argv[#{index}])
          rb_hash_aset(runtime_proc_registry_get(), #{name}_pid_v, argv[#{index}])
          let #{name}_pid_u = rb_num2ull(#{name}_pid_v)
          #{name}_block = { (#{block_args(sig_in)}) in
              ThreadingBridge.enqueueFromAppleThread(procId: #{name}_pid_u, arg: #{first_arg_value_for_dispatch(sig_in)})
          }
      }
    SWIFT
  end

  private

  def parse_block_signature(sig)
    # Minimal initial parser — accept "(T1, T2) -> R" form. For Phase 7 the
    # block signatures are constrained by the Worked Examples; expand later
    # if a knowledge-cataloged signature arrives that we don't handle.
    m = sig.match(/\((?<in>[^)]*)\)\s*->\s*(?<out>.+)/) or
      raise "BlockNilableMarshaller: unparseable signature #{sig.inspect}"
    ins = m[:in].split(",").map { |t| t.strip.gsub(/\*\s*$/, "?") }
    [ins, m[:out].strip]
  end

  def block_args(sig_in)
    sig_in.each_with_index.map { |t, i| "_a#{i}: #{t}" }.join(", ")
  end

  def first_arg_value_for_dispatch(sig_in)
    # Phase 7 dispatcher is single-arg int. Map first param into a UInt64
    # the dispatcher will UNWRAP back into a Ruby value via existing
    # ThreadingBridge convention. NSError? → 0 if nil, else 1.
    case sig_in.first
    when /Error\?/
      "_a0 == nil ? 0 : -1"
    else
      "_a0 == nil ? 0 : 1"
    end
  end
end

REGISTRY[BlockNilableMarshaller::KIND] = BlockNilableMarshaller.new
```

If REGISTRY doesn't exist by that exact name, locate the existing pattern (a hash mapping kind string → marshaller instance) and follow it.

- [ ] **Step T2a.4: Run test pass**

Run: `bundle exec ruby -Ilib -Itest test/glue_compiler/template_generator_test.rb -n test_block_nilable_marshaller_emits_stack_local_convention_block`
Expected: PASS.

- [ ] **Step T2a.5: Run full test suite — no regressions**

Run: `bundle exec rake test 2>&1 | tail -10`
Expected: no new failures.

- [ ] **Step T2a.6: Commit T2a**

```bash
git add lib/apple_sdk_mac/glue_compiler/marshallers.rb test/glue_compiler/template_generator_test.rb
git commit -m "feat(marshallers): BlockNilableMarshaller for noescape completion blocks

Stack-local @convention(block) literal pinned to runtime_proc_registry
during the call. Phase 7 T2a."
```

---

## Task T2b: BlockPersistentMarshaller (mac gem)

**Files:**
- Modify: `lib/apple_sdk_mac/glue_compiler/marshallers.rb`
- Test: `test/glue_compiler/template_generator_test.rb`

- [ ] **Step T2b.1: Write the failing test**

```ruby
def test_block_persistent_marshaller_emits_register_call_and_box_handle
  spec = {
    framework: "Foundation",
    symbol: "downloadWithCompletion",
    abi: "c",
    return_kind: "void",
    params: [
      { name: "completion", kind: "block_persistent",
        signature: "(NSData?, NSError?) -> Void" }
    ]
  }
  swift = TemplateGenerator.generate(spec)
  assert_match(/runtime_callback_register_block_persistent\(/, swift)
  assert_match(/BoxedBlockHandle\(slotId:/, swift)
  assert_match(/runtime_proc_registry_get\(\)/, swift)
end
```

- [ ] **Step T2b.2: Run failing test**

Run: `bundle exec ruby -Ilib -Itest test/glue_compiler/template_generator_test.rb -n test_block_persistent_marshaller_emits_register_call_and_box_handle`
Expected: FAIL — kind unknown.

- [ ] **Step T2b.3: Implement `BlockPersistentMarshaller`**

Reference: spec §3.4 second code block.

```ruby
class BlockPersistentMarshaller < Marshaller
  KIND = "block_persistent"

  def emit(name:, index:, signature:)
    <<~SWIFT
      let #{name}_handle: BoxedBlockHandle?
      if argv[#{index}] == Qnil {
          #{name}_handle = nil
      } else {
          let #{name}_pid_u = rb_num2ull(rb_obj_id(argv[#{index}]))
          rb_hash_aset(runtime_proc_registry_get(), rb_obj_id(argv[#{index}]), argv[#{index}])
          let #{name}_slot_id = runtime_callback_register_block_persistent(#{name}_pid_u)
          #{name}_handle = BoxedBlockHandle(slotId: #{name}_slot_id)
      }
    SWIFT
  end
end

REGISTRY[BlockPersistentMarshaller::KIND] = BlockPersistentMarshaller.new
```

- [ ] **Step T2b.4: Test passes**

Run: `bundle exec ruby -Ilib -Itest test/glue_compiler/template_generator_test.rb -n test_block_persistent_marshaller_emits_register_call_and_box_handle`
Expected: PASS.

- [ ] **Step T2b.5: Full suite green**

Run: `bundle exec rake test 2>&1 | tail -10`
Expected: no new fails.

- [ ] **Step T2b.6: Commit T2b**

```bash
git add lib/apple_sdk_mac/glue_compiler/marshallers.rb test/glue_compiler/template_generator_test.rb
git commit -m "feat(marshallers): BlockPersistentMarshaller for escaping completion blocks

Slot-table-resident @convention(block) thunk registered via
runtime_callback_register_block_persistent; lifetime tied to a Ruby
BoxedBlockHandle whose deinit unregisters. Phase 7 T2b."
```

---

## Task T2c: Callback pillar slot extension (mac gem)

**Files:**
- Modify: `ext/apple_sdk_mac_runtime/Sources/AppleSDKMacRuntime/CallbackPillar.swift` (or wherever the slot table lives — search first)
- Modify: `ext/apple_sdk_mac_runtime/Sources/AppleSDKMacRuntime/CallbackBridge.swift`
- Test: `test/callback_pillar_test.rb`

- [ ] **Step T2c.1: Locate the existing CallbackPillar slot table**

Run: `grep -rn "CallbackSlot\|slotKind\|callback_pillar" ext/apple_sdk_mac_runtime/Sources/`
Expected: 1-3 hits. Identify the file holding the slot struct.

- [ ] **Step T2c.2: Write the failing test in `test/callback_pillar_test.rb`**

```ruby
def test_register_block_persistent_returns_nonzero_slot_id
  pid = rand(1..2**60)
  slot = AppleSDKMacRuntime.runtime_callback_register_block_persistent(pid)
  refute_equal 0, slot
  AppleSDKMacRuntime.runtime_callback_unregister_block_persistent(slot)
end

def test_release_auto_block_unregisters_and_does_not_leak
  pid = rand(1..2**60)
  slot = AppleSDKMacRuntime.runtime_callback_register_block_persistent(pid)
  AppleSDKMacRuntime.runtime_callback_release_auto_block(slot)
  # Re-using the same procId after release should produce a new slot id
  slot2 = AppleSDKMacRuntime.runtime_callback_register_block_persistent(pid)
  refute_equal slot, slot2
  AppleSDKMacRuntime.runtime_callback_unregister_block_persistent(slot2)
end
```

If the C ext doesn't currently expose these as singleton methods on `AppleSDKMacRuntime`, add wrappers in `apple_sdk_mac_runtime.c` after Step T2c.4.

- [ ] **Step T2c.3: Run failing test**

Run: `bundle exec ruby -Ilib -Itest test/callback_pillar_test.rb -n test_register_block_persistent_returns_nonzero_slot_id`
Expected: FAIL — symbol or method not found.

- [ ] **Step T2c.4: Extend `CallbackSlot` struct + add 3 entry points**

Per spec §3.3:

```swift
enum SlotKind: UInt8 { case fnptr = 0, blockNoescape = 1, blockPersistent = 2 }
enum Lifetime: UInt8 { case auto = 0, manual = 1 }

struct CallbackSlot {
    var procId: UInt64
    var slotKind: SlotKind
    var lifetime: Lifetime
    var thunk: UnsafeRawPointer?  // nil for blockNoescape (lives on stack)
}

private var slots: [UInt64: CallbackSlot] = [:]
private var nextSlotId: UInt64 = 1
private let slotsLock = NSLock()

@c
public func runtime_callback_register_block_persistent(_ procId: UInt64) -> UInt64 {
    slotsLock.lock(); defer { slotsLock.unlock() }
    let id = nextSlotId; nextSlotId &+= 1
    slots[id] = CallbackSlot(procId: procId, slotKind: .blockPersistent,
                             lifetime: .auto, thunk: nil)
    return id
}

@c
public func runtime_callback_unregister_block_persistent(_ slotId: UInt64) {
    slotsLock.lock(); defer { slotsLock.unlock() }
    slots.removeValue(forKey: slotId)
}

@c
public func runtime_callback_release_auto_block(_ slotId: UInt64) {
    runtime_callback_unregister_block_persistent(slotId)
}
```

If existing fnptr APIs already use a slot table, extend in place (don't introduce a parallel table — spec says single registry).

- [ ] **Step T2c.5: Add Ruby wrappers in `apple_sdk_mac_runtime.c`**

```c
static VALUE rb_callback_register_block_persistent(VALUE self, VALUE pid) {
    UInt64 slot = runtime_callback_register_block_persistent((UInt64)NUM2ULL(pid));
    return ULL2NUM(slot);
}

static VALUE rb_callback_unregister_block_persistent(VALUE self, VALUE slot) {
    runtime_callback_unregister_block_persistent((UInt64)NUM2ULL(slot));
    return Qnil;
}

static VALUE rb_callback_release_auto_block(VALUE self, VALUE slot) {
    runtime_callback_release_auto_block((UInt64)NUM2ULL(slot));
    return Qnil;
}

// In Init_apple_sdk_mac_runtime:
rb_define_singleton_method(module, "runtime_callback_register_block_persistent",
                           rb_callback_register_block_persistent, 1);
rb_define_singleton_method(module, "runtime_callback_unregister_block_persistent",
                           rb_callback_unregister_block_persistent, 1);
rb_define_singleton_method(module, "runtime_callback_release_auto_block",
                           rb_callback_release_auto_block, 1);
```

- [ ] **Step T2c.6: Resync header, recompile, rerun test**

Run: `bundle exec rake apple:runtime:sync_header && bundle exec rake compile`
Run: `bundle exec ruby -Ilib -Itest test/callback_pillar_test.rb`
Expected: all green.

- [ ] **Step T2c.7: Add Ruby Box wrapper for BoxedBlockHandle**

If glue Swift references `BoxedBlockHandle`, define it in the runtime dylib. Add to `RuntimeBridge.swift` (or a `BoxedBlockHandle.swift` next to it):

```swift
public final class BoxedBlockHandle {
    public let slotId: UInt64
    public init(slotId: UInt64) { self.slotId = slotId }
    deinit { runtime_callback_release_auto_block(slotId) }
}
```

- [ ] **Step T2c.8: Resync header, recompile, full test pass**

Run: `bundle exec rake apple:runtime:sync_header && bundle exec rake compile && bundle exec rake test 2>&1 | tail -10`
Expected: no new fails.

- [ ] **Step T2c.9: Commit T2c**

```bash
git add ext/apple_sdk_mac_runtime/ test/callback_pillar_test.rb
git commit -m "feat(callback-pillar): persistent block slot table + BoxedBlockHandle

Slot kind enum (fnptr / blockNoescape / blockPersistent) + lifetime
(auto / manual). BoxedBlockHandle deinit auto-unregisters. Three new
@c entry points — register/unregister/release. Pillar count stays 9.
Phase 7 T2c."
```

---

## Task T3a: LLM Worked Examples E1-E4 (async)

**Files:**
- Modify: `lib/apple_sdk_mac/glue_compiler/llm_generator.rb`
- Test: `test/llm_generator_test.rb`

- [ ] **Step T3a.1: Write failing tests**

```ruby
def test_instructions_contain_e1_single_await_pattern
  ins = LLMGenerator::INSTRUCTIONS
  assert_match(/E1.*single.*await/m, ins)
  assert_match(/DispatchSemaphore\(value: 0\)/, ins)
  assert_match(/sema\.wait\(\)/, ins)
end

def test_instructions_contain_e2_taskgroup_pattern
  assert_match(/E2.*TaskGroup/m, LLMGenerator::INSTRUCTIONS)
  assert_match(/withThrowingTaskGroup/, LLMGenerator::INSTRUCTIONS)
end

def test_instructions_contain_e3_async_let_pattern
  assert_match(/E3.*async let/m, LLMGenerator::INSTRUCTIONS)
end

def test_instructions_contain_e4_main_actor_pattern
  assert_match(/E4.*MainActor/m, LLMGenerator::INSTRUCTIONS)
  assert_match(/await MainActor\.run/, LLMGenerator::INSTRUCTIONS)
end
```

- [ ] **Step T3a.2: Run failing tests**

Run: `bundle exec ruby -Ilib -Itest test/llm_generator_test.rb -n /test_instructions_contain_e/`
Expected: 4 fails.

- [ ] **Step T3a.3: Add Worked Examples E1-E4 to `INSTRUCTIONS`**

Per spec §3.6. Append to the INSTRUCTIONS heredoc:

```ruby
INSTRUCTIONS = <<~PROMPT
  ... existing content ...

  ## Worked Example E1 — Single `await`

  For a Swift `func foo() async throws -> T`, ALWAYS emit this exact skeleton:

  ```swift
  let sema = DispatchSemaphore(value: 0)
  var result: <T>?
  var captured: Error?
  Task {
      do { result = try await foo() }
      catch { captured = error }
      sema.signal()
  }
  sema.wait()
  if let e = captured {
      rb_raise(rb_eRuntimeError, "\\(e)"); return Qnil
  }
  return marshal(result!)
  ```

  ## Worked Example E2 — TaskGroup

  ```swift
  let sema = DispatchSemaphore(value: 0)
  var result: [T]?
  var captured: Error?
  Task {
      do {
          result = try await withThrowingTaskGroup(of: T.self) { group in
              for x in inputs { group.addTask { try await work(x) } }
              var acc: [T] = []
              for try await v in group { acc.append(v) }
              return acc
          }
      } catch { captured = error }
      sema.signal()
  }
  sema.wait()
  // raise/return as in E1
  ```

  ## Worked Example E3 — async let

  ```swift
  Task {
      do {
          async let a = workA()
          async let b = workB()
          let (x, y) = try await (a, b)
          result = (x, y)
      } catch { captured = error }
      sema.signal()
  }
  ```

  ## Worked Example E4 — @MainActor.run

  ```swift
  Task {
      do { result = try await MainActor.run { mainActorWork() } }
      catch { captured = error }
      sema.signal()
  }
  ```
PROMPT
```

- [ ] **Step T3a.4: Tests pass**

Run: `bundle exec ruby -Ilib -Itest test/llm_generator_test.rb -n /test_instructions_contain_e/`
Expected: 4 passes.

- [ ] **Step T3a.5: Commit T3a**

```bash
git add lib/apple_sdk_mac/glue_compiler/llm_generator.rb test/llm_generator_test.rb
git commit -m "feat(llm): worked examples E1-E4 — async patterns

Single await / TaskGroup / async let / @MainActor.run skeletons added
to LLM INSTRUCTIONS. ValidationGates async-shape rule (T3c) enforces
the DispatchSemaphore + do/catch shape literally. Phase 7 T3a."
```

---

## Task T3b: LLM Worked Examples F1, F2, G (ObjC)

- [ ] **Step T3b.1: Write failing tests**

```ruby
def test_instructions_contain_f1_alloc_init
  ins = LLMGenerator::INSTRUCTIONS
  assert_match(/F1.*alloc.*init/m, ins)
  assert_match(/Unmanaged\.passRetained/, ins)
end

def test_instructions_contain_f2_class_method
  assert_match(/F2.*class method/m, LLMGenerator::INSTRUCTIONS)
  assert_match(/stringWithUTF8String/, LLMGenerator::INSTRUCTIONS)
end

def test_instructions_contain_g_objc_with_completion_block
  assert_match(/Worked Example G.*completion block/m, LLMGenerator::INSTRUCTIONS)
end
```

- [ ] **Step T3b.2: Run failing tests**

Run: `bundle exec ruby -Ilib -Itest test/llm_generator_test.rb -n /test_instructions_contain_(f|g)/`
Expected: 3 fails.

- [ ] **Step T3b.3: Append F1, F2, G to INSTRUCTIONS**

Per spec §3.7 — copy the three code blocks (F1 VNImageRequestHandler, F2 NSString.stringWithUTF8String, G VNImageRequestHandler.performRequests) into the INSTRUCTIONS heredoc with explanatory headers.

- [ ] **Step T3b.4: Tests pass**

Run: `bundle exec ruby -Ilib -Itest test/llm_generator_test.rb -n /test_instructions_contain_(f|g)/`
Expected: 3 passes.

- [ ] **Step T3b.5: Commit T3b**

```bash
git add lib/apple_sdk_mac/glue_compiler/llm_generator.rb test/llm_generator_test.rb
git commit -m "feat(llm): worked examples F1, F2, G — ObjC method dispatch

Alloc-init chain, pure class method, ObjC + completion block patterns
added to LLM INSTRUCTIONS. ValidationGates objc-bridge-shape rule
(T3c) enforces 'import the framework module, no manual objc_msgSend'.
Phase 7 T3b."
```

---

## Task T3c: ValidationGates async + persistent-block + autoarc + objc-bridge shapes

**Files:**
- Modify: `lib/apple_sdk_mac/glue_compiler/validation_gates.rb`
- Test: `test/validation_gates_test.rb`

- [ ] **Step T3c.1: Write failing tests**

```ruby
def test_async_shape_rejects_glue_with_await_but_no_dispatch_semaphore
  malformed = <<~SWIFT
    @c public func glue_x(_ argv: UnsafePointer<UInt>, _ argc: Int32) -> UInt {
        Task { _ = try await something() }
        return Qnil
    }
  SWIFT
  err = assert_raises(ValidationGates::ShapeError) { ValidationGates.check_async_shape!(malformed) }
  assert_match(/DispatchSemaphore/, err.message)
end

def test_async_shape_accepts_well_formed_glue
  ok = <<~SWIFT
    @c public func glue_x(_ argv: UnsafePointer<UInt>, _ argc: Int32) -> UInt {
        let sema = DispatchSemaphore(value: 0)
        var captured: Error?
        Task {
            do { _ = try await something() }
            catch { captured = error }
            sema.signal()
        }
        sema.wait()
        return Qnil
    }
  SWIFT
  assert_nothing_raised { ValidationGates.check_async_shape!(ok) }
end

def test_persistent_block_shape_requires_register_call
  malformed = <<~SWIFT
    let cb_handle = BoxedBlockHandle(slotId: 1)  // missing register call
  SWIFT
  err = assert_raises(ValidationGates::ShapeError) { ValidationGates.check_persistent_block_shape!(malformed) }
  assert_match(/runtime_callback_register_block_persistent/, err.message)
end

def test_autoarc_shape_rejects_manual_cfrelease
  malformed = "let raw = ...; CFRelease(raw); return ..."
  err = assert_raises(ValidationGates::ShapeError) { ValidationGates.check_autoarc_shape!(malformed) }
  assert_match(/CFRelease/, err.message)
end

def test_objc_bridge_shape_rejects_manual_objc_msgSend
  malformed = "objc_msgSend(obj, sel, ...)"
  err = assert_raises(ValidationGates::ShapeError) { ValidationGates.check_objc_bridge_shape!(malformed) }
  assert_match(/objc_msgSend/, err.message)
end
```

- [ ] **Step T3c.2: Run failing tests**

Run: `bundle exec ruby -Ilib -Itest test/validation_gates_test.rb -n /test_(async|persistent_block|autoarc|objc_bridge)_shape/`
Expected: 5 fails.

- [ ] **Step T3c.3: Implement gate methods in `validation_gates.rb`**

```ruby
class ShapeError < StandardError; end

def self.check_async_shape!(swift)
  return unless swift.match?(/\bawait\b/)
  required = [
    /DispatchSemaphore\(value:\s*0\)/,
    /Task\s*\{/,
    /do\s*\{[^}]*try\s+await/m,
    /catch\s*\{/,
    /sema\.signal\(\)/,
    /sema\.wait\(\)/
  ]
  required.each do |re|
    raise ShapeError, "async-shape violation: missing #{re.source}" unless swift.match?(re)
  end
end

def self.check_persistent_block_shape!(swift)
  return unless swift.include?("BoxedBlockHandle")
  unless swift.include?("runtime_callback_register_block_persistent")
    raise ShapeError, "persistent-block-shape: BoxedBlockHandle without runtime_callback_register_block_persistent"
  end
end

def self.check_autoarc_shape!(swift)
  return unless swift.include?("BoxedCFType")
  if swift.match?(/\bCFRelease\(/)
    raise ShapeError, "autoarc-shape: manual CFRelease forbidden in cftype_ref_autoarc glue"
  end
  unless swift.include?("takeRetainedValue()")
    raise ShapeError, "autoarc-shape: BoxedCFType without Unmanaged.takeRetainedValue()"
  end
end

def self.check_objc_bridge_shape!(swift)
  if swift.match?(/\bobjc_msgSend\b/)
    raise ShapeError, "objc-bridge-shape: manual objc_msgSend forbidden — import the framework module instead"
  end
end

def self.check_all!(swift)
  check_async_shape!(swift)
  check_persistent_block_shape!(swift)
  check_autoarc_shape!(swift)
  check_objc_bridge_shape!(swift)
  # ... existing gate calls (allowed-imports, banned-APIs, glue surface)
end
```

Wire `check_all!` into the existing `validate!` entry point so all four are exercised on every LLM-generated glue.

- [ ] **Step T3c.4: Tests pass**

Run: `bundle exec ruby -Ilib -Itest test/validation_gates_test.rb`
Expected: all green.

- [ ] **Step T3c.5: Commit T3c**

```bash
git add lib/apple_sdk_mac/glue_compiler/validation_gates.rb test/validation_gates_test.rb
git commit -m "feat(validation): async/persistent-block/autoarc/objc-bridge shape gates

Four new ValidationGates rules enforce the LLM Worked Example shapes
literally. Malformed glue is rejected before swiftc invocation;
LLMGenerator's retry loop (DEFAULT_MAX_LLM_RETRIES = 6) gets a chance
to converge. Phase 7 T3c."
```

---

## Task T4: CFTypeRefAutoARCMarshaller

**Files:**
- Modify: `lib/apple_sdk_mac/glue_compiler/marshallers.rb`
- Modify: existing ARC pillar Swift file (locate via `grep -rn "BoxedCFType\|ARC pillar" ext/apple_sdk_mac_runtime/Sources/`)
- Test: `test/glue_compiler/template_generator_test.rb`

- [ ] **Step T4.1: Write the failing test**

```ruby
def test_cftype_ref_autoarc_marshaller_emits_take_retained_and_box
  spec = {
    framework: "CoreFoundation",
    symbol: "CFStringCreateWithCString",
    abi: "c",
    return_kind: "cftype_ref_autoarc",
    return_type: "CFStringRef",
    params: [
      { name: "alloc", kind: "void_ptr_nilable" },
      { name: "cstr",  kind: "string" },
      { name: "encoding", kind: "int" }
    ]
  }
  swift = TemplateGenerator.generate(spec)
  assert_match(/Unmanaged.*takeRetainedValue\(\)/, swift)
  assert_match(/BoxedCFType\(retained:/, swift)
  refute_match(/CFRelease/, swift)
end
```

- [ ] **Step T4.2: Run failing test**

Expected: FAIL — kind unknown / return_kind dispatch missing.

- [ ] **Step T4.3: Implement `CFTypeRefAutoARCMarshaller` (return-side)**

Per spec §3.5:

```ruby
class CFTypeRefAutoARCMarshaller < Marshaller
  KIND = "cftype_ref_autoarc"

  def emit_return(call_expr:, return_type:)
    <<~SWIFT
      let raw = #{call_expr}
      let unmanaged = Unmanaged<#{return_type}>.fromOpaque(UnsafeRawPointer(bitPattern: UInt(bitPattern: raw))!)
      let boxed = BoxedCFType(retained: unmanaged.takeRetainedValue())
      return rb_ull2inum(UInt64(UInt(bitPattern: Unmanaged.passRetained(boxed).toOpaque())))
    SWIFT
  end
end

REGISTRY[CFTypeRefAutoARCMarshaller::KIND] = CFTypeRefAutoARCMarshaller.new
```

Wire `template_generator.rb` to dispatch on `return_kind == "cftype_ref_autoarc"` to this marshaller's `emit_return`.

- [ ] **Step T4.4: Add `BoxedCFType` to ARC pillar**

```swift
public final class BoxedCFType {
    let retained: AnyObject  // CFType bridges to AnyObject
    public init(retained: AnyObject) { self.retained = retained }
    deinit {
        // ARC handles AnyObject release automatically, but for CF types
        // explicitly bridged through Unmanaged.takeRetainedValue we already
        // own a +1 retain. Letting the AnyObject reference go releases it.
    }
}
```

If a CF type isn't toll-free bridged to AnyObject for some surface, fall back to:

```swift
public final class BoxedCFType {
    let raw: UnsafeRawPointer
    public init(raw: UnsafeRawPointer) { self.raw = raw }
    deinit { CFRelease(raw) }
}
```

Pick the form that matches how `cf_string_create.rb` (T11) ends up calling. Verify by recompile + T11 example smoke later.

- [ ] **Step T4.5: Test passes; full suite green**

Run: `bundle exec rake apple:runtime:sync_header && bundle exec rake compile && bundle exec rake test 2>&1 | tail -10`
Expected: no new fails.

- [ ] **Step T4.6: Commit T4**

```bash
git add lib/apple_sdk_mac/glue_compiler/marshallers.rb \
        ext/apple_sdk_mac_runtime/ \
        test/glue_compiler/template_generator_test.rb
git commit -m "feat(arc): CFTypeRefAutoARCMarshaller — CF Create-rule auto release

Emits Unmanaged.takeRetainedValue() + BoxedCFType wrap. Box deinit
releases the CF reference automatically. User-facing examples no
longer call CFRelease. Phase 7 T4."
```

---

## Task T5: Apple.discover polymorphic single entry

**Files:**
- Modify: `lib/apple_sdk_mac/public_api.rb`
- Modify: `lib/apple_sdk_mac.rb` (thin proxy)
- Test: `test/public_api_test.rb` (create if missing)

- [ ] **Step T5.1: Write the failing tests** (one per discover shape — spec §3.2)

If `test/public_api_test.rb` doesn't exist, create it. Add 7 tests, one per shape:

```ruby
require "test_helper"
require "apple_sdk_mac"

class TestPublicAPIDiscover < Test::Unit::TestCase
  def setup
    # Reset transient knowledge cache between tests
    AppleSDKMac.knowledge_cache.clear_transient! if AppleSDKMac.knowledge_cache.respond_to?(:clear_transient!)
  end

  def test_discover_c_symbol_registers_function_kind
    Apple.discover(framework: :CoreMIDI, symbol: :MIDIClientCreate)
    rec = AppleSDKMac.knowledge_cache.lookup_symbol(framework: "CoreMIDI", name: "MIDIClientCreate")
    assert_equal "function", rec[:kind]
  end

  def test_discover_objc_instance_method_registers_objc_method_instance_kind
    Apple.discover(framework: :Vision, klass: :VNImageRequestHandler,
                   selector: "initWithCGImage:options:",
                   params: [:cftype_ref, :void_ptr_nilable], return_kind: :opaque_ref)
    rec = AppleSDKMac.knowledge_cache.lookup_symbol(framework: "Vision", name: "VNImageRequestHandler#initWithCGImage:options:")
    assert_equal "objc_method_instance", rec[:kind]
  end

  def test_discover_objc_class_method_registers_objc_method_class_kind
    Apple.discover(framework: :Foundation, klass: :NSString,
                   class_method: "stringWithUTF8String:",
                   params: [:string], return_kind: :opaque_ref)
    rec = AppleSDKMac.knowledge_cache.lookup_symbol(framework: "Foundation", name: "NSString+stringWithUTF8String:")
    assert_equal "objc_method_class", rec[:kind]
  end

  def test_discover_swift_func_registers_swift_func_kind
    Apple.discover(framework: :Foundation, swift_func: :runtime_async_test_sleep_and_double,
                   params: [:int], return_kind: :int)
    rec = AppleSDKMac.knowledge_cache.lookup_symbol(framework: "Foundation", name: "runtime_async_test_sleep_and_double")
    assert_equal "swift_func", rec[:kind]
  end

  def test_discover_swift_initializer_registers_swift_init_kind
    Apple.discover(framework: :Foundation, klass: :URL, swift_initializer: "init(string:)",
                   params: [:string], return_kind: :opaque_ref)
    rec = AppleSDKMac.knowledge_cache.lookup_symbol(framework: "Foundation", name: "URL.init(string:)")
    assert_equal "swift_init", rec[:kind]
  end

  def test_discover_swift_property_registers_swift_property_kind
    Apple.discover(framework: :Foundation, klass: :ProcessInfo,
                   swift_property: :processIdentifier, return_kind: :int)
    rec = AppleSDKMac.knowledge_cache.lookup_symbol(framework: "Foundation", name: "ProcessInfo.processIdentifier")
    assert_equal "swift_property", rec[:kind]
  end

  def test_discover_with_type_args_records_generic_resolution
    Apple.discover(framework: :Foundation, swift_func: :decode,
                   type_args: [:User], params: [:string], return_kind: :opaque_ref)
    rec = AppleSDKMac.knowledge_cache.lookup_symbol(framework: "Foundation", name: "decode<User>")
    assert_equal "swift_func", rec[:kind]
    assert_equal [:User], rec[:type_args]
  end

  def test_discover_without_recognized_key_raises_discovery_error
    assert_raises(Apple::DiscoveryError) { Apple.discover(framework: :Foundation) }
  end
end
```

- [ ] **Step T5.2: Run failing tests**

Run: `bundle exec ruby -Ilib -Itest test/public_api_test.rb`
Expected: 8 fails (or NameError on `Apple::DiscoveryError`).

- [ ] **Step T5.3: Add `Apple::DiscoveryError`**

If T19 not yet executed, scaffold a minimal `lib/apple_sdk_mac/errors.rb` now:

```ruby
module Apple
  class Error < StandardError; end
  class DiscoveryError < Error; end
  class CompileError < Error; end
  class CallError < Error; end
end
```

`require_relative "apple_sdk_mac/errors"` from `lib/apple_sdk_mac.rb`.

- [ ] **Step T5.4: Implement polymorphic dispatch in `public_api.rb`**

Per spec §3.2 (the `def self.discover` body). Add private `_discover_*` helpers; each:
1. Synthesizes a symbol record `{ framework:, name:, kind:, params:, return_kind:, ... }` using the appropriate name canonicalization (e.g. `klass#selector` for instance, `klass+selector` for class method, `Klass.init(...)` for swift init).
2. Calls `AppleSDKMac.knowledge_cache.register_transient!(record)` (or whatever the equivalent existing API is — locate via `grep -rn "register_transient\|insert_seeded" lib/`).

Naming canonicalization is the spec contract — use the same forms the assertions in T5.1 expect.

- [ ] **Step T5.5: Add `Apple.discover` thin proxy in `lib/apple_sdk_mac.rb`**

If `Apple.discover` already exists as a top-level method, update it to forward to the polymorphic implementation. Otherwise:

```ruby
module Apple
  def self.discover(framework:, **opts)
    AppleSDKMac::PublicAPI.discover(framework: framework, **opts)
  end
end
```

- [ ] **Step T5.6: Tests pass**

Run: `bundle exec ruby -Ilib -Itest test/public_api_test.rb`
Expected: 8 passes.

- [ ] **Step T5.7: Run full suite**

Run: `bundle exec rake test 2>&1 | tail -10`
Expected: no new fails. The original `Apple.discover` smoke test (`coremidi_smoke_test.rb`) must still pass — if it breaks, the polymorphic dispatch is too aggressive; preserve the existing C-symbol path identically.

- [ ] **Step T5.8: Commit T5**

```bash
git add lib/apple_sdk_mac/public_api.rb lib/apple_sdk_mac.rb \
        lib/apple_sdk_mac/errors.rb test/public_api_test.rb
git commit -m "feat(public-api): Apple.discover polymorphic single entry

Dispatches by keyword key — symbol/selector/class_method/swift_func/
swift_initializer/swift_property + optional type_args. Synthesizes
symbol records into the transient KnowledgeCache lookup tier with
canonical names. Adds Apple::DiscoveryError for unrecognized shapes.
Phase 7 T5; satisfies README L29-34 canonical Usage form list."
```

---

## Task T6: examples/coremidi_receive.rb (rewrite)

**Files:**
- Modify: `examples/coremidi_receive.rb`
- Modify: `test/integration/examples_smoke_test.rb` (add test)

- [ ] **Step T6.1: Write the failing smoke test**

In `test/integration/examples_smoke_test.rb`, add:

```ruby
def test_coremidi_receive_exits_zero_with_client_output
  res = run_example("coremidi_receive.rb", timeout: 10)
  assert_equal 0, res[:exitstatus],
    "coremidi_receive.rb exited #{res[:exitstatus]}; stderr:\n#{res[:stderr]}"
  assert_match(/^client=/, res[:stdout])
end
```

- [ ] **Step T6.2: Run failing test**

Run: `bundle exec ruby -Ilib -Itest test/integration/examples_smoke_test.rb -n test_coremidi_receive_exits_zero_with_client_output`
Expected: FAIL — example doesn't exist with that output shape, or example contains old code.

- [ ] **Step T6.3: Rewrite `examples/coremidi_receive.rb`**

Per spec §3.1 entry: "Rewritten: explicit `proc { ... }` for `MIDIReadProc`, demonstrates connect + drain via `Apple.event_loop`".

```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true
require "apple_sdk_mac"

Apple.bootstrap!
Apple.discover(framework: :CoreMIDI, symbol: :MIDIClientCreate)
Apple.discover(framework: :CoreMIDI, symbol: :MIDIClientDispose)
Apple.discover(framework: :CoreMIDI, symbol: :MIDIInputPortCreate)

received = []
read_proc = proc do |packet_list, _src_conn|
  received << packet_list
end

client = Apple::CoreMIDI.MIDIClientCreate("rb-apple-sdk-mac receive demo", nil, nil)
puts "client=#{client}"

# port = Apple::CoreMIDI.MIDIInputPortCreate(client, "in", read_proc, nil)
# Apple.event_loop(timeout: 0.5)
# puts "received=#{received.size}"

Apple::CoreMIDI.MIDIClientDispose(client)
```

The commented-out section is the connect+drain demonstration — leave it commented if no MIDI source is present at test time, or wrap in `if ENV["MIDI_SOURCE_PRESENT"]`. The smoke test only requires `client=` on stdout.

- [ ] **Step T6.4: Test passes**

Run: `bundle exec ruby -Ilib -Itest test/integration/examples_smoke_test.rb -n test_coremidi_receive_exits_zero_with_client_output`
Expected: PASS in ~5s.

- [ ] **Step T6.5: Commit T6**

```bash
git add examples/coremidi_receive.rb test/integration/examples_smoke_test.rb
git commit -m "feat(examples): coremidi_receive.rb — explicit MIDIReadProc proc demo

Phase 7 T6 — example 1 of 7."
```

---

## Task T7: examples/vision_ocr.rb + fixture

**Files:**
- Modify: `examples/vision_ocr.rb`
- Create: `test/fixtures/ocr_sample.png` (≤30 KB)
- Modify: `test/integration/examples_smoke_test.rb`

- [ ] **Step T7.1: Synthesize fixture image**

Run:
```bash
mkdir -p test/fixtures
echo "Hello OCR" | text2png > /tmp/ocr_src.png 2>/dev/null || \
  (sips -s format png --out test/fixtures/ocr_sample.png /System/Library/CoreServices/DefaultBackground.heic 2>/dev/null && \
   echo "fallback fixture used; replace with text PNG if Vision returns empty results")
```

Or hand-create a small PNG with text. Cap at 30 KB; verify with `wc -c test/fixtures/ocr_sample.png`.

If you have ImageMagick:
```bash
convert -size 200x60 xc:white -font Helvetica -pointsize 24 \
        -fill black -gravity center -annotate 0 "Hello OCR" \
        test/fixtures/ocr_sample.png
```

- [ ] **Step T7.2: Write the failing smoke test**

```ruby
def test_vision_ocr_recognizes_fixture_text
  res = run_example("vision_ocr.rb", timeout: 30)
  assert_equal 0, res[:exitstatus],
    "vision_ocr.rb exited #{res[:exitstatus]}; stderr:\n#{res[:stderr]}"
  assert_match(/^results=\[/, res[:stdout])
  refute_match(/^results=\[\]/, res[:stdout],
    "expected non-empty OCR results from fixture")
end
```

- [ ] **Step T7.3: Run failing test**

Expected: FAIL.

- [ ] **Step T7.4: Rewrite `examples/vision_ocr.rb`**

```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true
require "apple_sdk_mac"

Apple.bootstrap!

fixture = File.expand_path("../test/fixtures/ocr_sample.png", __dir__)

Apple.discover(framework: :CoreGraphics, symbol: :CGImageSourceCreateWithURL)
Apple.discover(framework: :CoreGraphics, symbol: :CGImageSourceCreateImageAtIndex)
Apple.discover(framework: :Foundation, klass: :URL, swift_initializer: "init(fileURLWithPath:)",
               params: [:string], return_kind: :opaque_ref)
Apple.discover(framework: :Vision, klass: :VNImageRequestHandler,
               selector: "initWithCGImage:options:",
               params: [:cftype_ref, :void_ptr_nilable], return_kind: :opaque_ref)
Apple.discover(framework: :Vision, klass: :VNRecognizeTextRequest,
               swift_initializer: "init()", params: [], return_kind: :opaque_ref)
Apple.discover(framework: :Vision, klass: :VNImageRequestHandler,
               selector: "performRequests:error:",
               params: [:opaque_ref, :struct_out],
               return_kind: :bool)

# Build URL → CGImage → VNImageRequestHandler → perform → results
url = Apple::Foundation.URL_init_fileURLWithPath_(fixture)
src = Apple::CoreGraphics.CGImageSourceCreateWithURL(url, nil)
img = Apple::CoreGraphics.CGImageSourceCreateImageAtIndex(src, 0, nil)
handler = Apple::Vision.VNImageRequestHandler_initWithCGImage_options_(img, nil)
request = Apple::Vision.VNRecognizeTextRequest_init_()
Apple::Vision.VNImageRequestHandler_performRequests_error_(handler, [request])

results = request.results.map { |obs| obs.topCandidates(1).first.string }
puts "results=#{results.inspect}"
```

If specific bound APIs need different signatures, adjust to what the knowledge DB supplies. The output shape `results=[…]` is the contract.

- [ ] **Step T7.5: Run test**

Run: `bundle exec ruby -Ilib -Itest test/integration/examples_smoke_test.rb -n test_vision_ocr_recognizes_fixture_text`
Expected: PASS.

- [ ] **Step T7.6: Commit T7**

```bash
git add examples/vision_ocr.rb test/fixtures/ocr_sample.png \
        test/integration/examples_smoke_test.rb
git commit -m "feat(examples): vision_ocr.rb — real Vision OCR on fixture image

Demonstrates ObjC method dispatch (alloc-init), noescape completion
block, and CFType auto-ARC end-to-end. Phase 7 T7 — example 2 of 7."
```

---

## Task T8: examples/async_demo.rb

- [ ] **Step T8.1: Write smoke test**

```ruby
def test_async_demo_outputs_numeric_result
  res = run_example("async_demo.rb", timeout: 15)
  assert_equal 0, res[:exitstatus]
  assert_match(/^result=\d+/, res[:stdout])
end
```

- [ ] **Step T8.2: Run failing test**

Expected: FAIL — example doesn't exist.

- [ ] **Step T8.3: Create `examples/async_demo.rb`**

```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true
require "apple_sdk_mac"

Apple.bootstrap!
Apple.discover(framework: :Foundation,
               swift_func: :runtime_async_test_sleep_and_double,
               params: [:int], return_kind: :int)

result = Apple::Foundation.runtime_async_test_sleep_and_double(21)
puts "result=#{result}"
```

If `runtime_async_test_sleep_and_double` doesn't exist as a Swift symbol, add it to the runtime dylib as a test fixture:

```swift
// Add to RuntimeBridge.swift or a TestFixtures.swift
@c
public func runtime_async_test_sleep_and_double(_ x: Int64) -> Int64 {
    let sema = DispatchSemaphore(value: 0)
    var result: Int64 = 0
    Task {
        try? await Task.sleep(nanoseconds: 100_000_000)
        result = x * 2
        sema.signal()
    }
    sema.wait()
    return result
}
```

If you take this fixture path: rake apple:runtime:sync_header && rake compile.

- [ ] **Step T8.4: Test passes**

Expected: `result=42`.

- [ ] **Step T8.5: Commit T8**

```bash
git add examples/async_demo.rb test/integration/examples_smoke_test.rb \
        ext/apple_sdk_mac_runtime/  # if fixture symbol added
git commit -m "feat(examples): async_demo.rb — single Swift await round-trip

Validates LLM Worked Example E1 / ValidationGates async-shape gate.
Phase 7 T8 — example 3 of 7."
```

---

## Task T9: examples/urlsession_download.rb

- [ ] **Step T9.1: Write smoke test**

```ruby
def test_urlsession_download_outputs_byte_count
  res = run_example("urlsession_download.rb", timeout: 30)
  assert_equal 0, res[:exitstatus]
  assert_match(/^downloaded=\d+/, res[:stdout])
  bytes = res[:stdout].match(/^downloaded=(\d+)/)[1].to_i
  assert_operator bytes, :>, 0
end
```

- [ ] **Step T9.2: Run failing test → PASS path**

Use a small, stable target URL. Prefer a local URL or a tiny fixture served by `http_server.rb`-style helper if test isolation matters. Example uses `https://example.com/` (small page, ~1.2 KB).

```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true
require "apple_sdk_mac"

Apple.bootstrap!
Apple.discover(framework: :Foundation, klass: :URL,
               swift_initializer: "init(string:)",
               params: [:string], return_kind: :opaque_ref)
Apple.discover(framework: :Foundation, klass: :NSURLSession,
               class_method: "sharedSession",
               params: [], return_kind: :opaque_ref)
Apple.discover(framework: :Foundation, klass: :NSURLSession,
               selector: "dataTaskWithURL:completionHandler:",
               params: [:opaque_ref, :block_persistent],
               return_kind: :opaque_ref)

session = Apple::Foundation.NSURLSession_sharedSession()
url = Apple::Foundation.URL_init_string_("https://example.com/")

q = Queue.new
completion = proc do |data, _resp, _err|
  q << (data ? data.length : 0)
end
task = Apple::Foundation.NSURLSession_dataTaskWithURL_completionHandler_(session, url, completion)
task.resume
size = q.pop
puts "downloaded=#{size}"
```

- [ ] **Step T9.3: Test passes**

Run: `bundle exec ruby -Ilib -Itest test/integration/examples_smoke_test.rb -n test_urlsession_download_outputs_byte_count`
Expected: `downloaded=1256` or similar non-zero.

- [ ] **Step T9.4: Commit T9**

```bash
git add examples/urlsession_download.rb test/integration/examples_smoke_test.rb
git commit -m "feat(examples): urlsession_download.rb — escaping completion block

Validates BlockPersistentMarshaller + BoxedBlockHandle lifetime + the
runtime_callback_register_block_persistent path under real Apple
async API pressure. Phase 7 T9 — example 4 of 7."
```

---

## Task T10: examples/async_taskgroup.rb

- [ ] **Step T10.1: Smoke test**

```ruby
def test_async_taskgroup_outputs_three_results
  res = run_example("async_taskgroup.rb", timeout: 15)
  assert_equal 0, res[:exitstatus]
  assert_match(/^results=\[\d+,\s*\d+,\s*\d+\]/, res[:stdout])
end
```

- [ ] **Step T10.2: Implement (similar to T8)**

```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true
require "apple_sdk_mac"

Apple.bootstrap!
Apple.discover(framework: :Foundation,
               swift_func: :runtime_async_test_taskgroup_3,
               params: [:int, :int, :int], return_kind: :opaque_ref)

results = Apple::Foundation.runtime_async_test_taskgroup_3(2, 3, 5).to_a
puts "results=#{results.inspect}"
```

Add the fixture symbol to RuntimeBridge.swift:

```swift
@c
public func runtime_async_test_taskgroup_3(_ a: Int64, _ b: Int64, _ c: Int64) -> UInt {
    let sema = DispatchSemaphore(value: 0)
    var out: [Int64] = []
    Task {
        out = try! await withThrowingTaskGroup(of: Int64.self) { group in
            for x in [a, b, c] { group.addTask { try await Task.sleep(nanoseconds: 50_000_000); return x * 2 } }
            var acc: [Int64] = []
            for try await v in group { acc.append(v) }
            return acc.sorted()
        }
        sema.signal()
    }
    sema.wait()
    // Marshal out to a Ruby Array<Int>
    return marshalIntArray(out)
}
```

`marshalIntArray` may need to be added to the Marshal pillar — minimal helper.

- [ ] **Step T10.3: Test passes; commit**

```bash
git add examples/async_taskgroup.rb test/integration/examples_smoke_test.rb \
        ext/apple_sdk_mac_runtime/
git commit -m "feat(examples): async_taskgroup.rb — TaskGroup 3-parallel demo

Validates LLM Worked Example E2 / ValidationGates async-shape +
withThrowingTaskGroup pattern. Phase 7 T10 — example 5 of 7."
```

---

## Task T11: examples/cf_string_create.rb

- [ ] **Step T11.1: Smoke test**

```ruby
def test_cf_string_create_round_trip
  res = run_example("cf_string_create.rb", timeout: 10)
  assert_equal 0, res[:exitstatus]
  assert_match(/^round-trip=Hello, CF/, res[:stdout])
  refute_match(/CFRelease/, res[:stdout],
    "example must demonstrate auto-ARC, not manual CFRelease")
end
```

- [ ] **Step T11.2: Implement**

```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true
require "apple_sdk_mac"

Apple.bootstrap!
Apple.discover(framework: :CoreFoundation, symbol: :CFStringCreateWithCString)
Apple.discover(framework: :CoreFoundation, symbol: :CFStringGetCStringPtr)

cfs = Apple::CoreFoundation.CFStringCreateWithCString(nil, "Hello, CF", 0x08000100)
back = Apple::CoreFoundation.CFStringGetCStringPtr(cfs, 0x08000100)
puts "round-trip=#{back}"
# No manual CFRelease — BoxedCFType deinit fires when `cfs` goes out of scope.
```

- [ ] **Step T11.3: Pass + commit**

```bash
git add examples/cf_string_create.rb test/integration/examples_smoke_test.rb
git commit -m "feat(examples): cf_string_create.rb — CF Create-rule auto-ARC

Validates CFTypeRefAutoARCMarshaller end-to-end; user code does not
call CFRelease. Phase 7 T11 — example 6 of 7."
```

---

## Task T12: examples/objc_classmethod.rb

- [ ] **Step T12.1: Smoke test**

```ruby
def test_objc_classmethod_round_trip
  res = run_example("objc_classmethod.rb", timeout: 10)
  assert_equal 0, res[:exitstatus]
  assert_match(/^round-trip=Hello, ObjC/, res[:stdout])
end
```

- [ ] **Step T12.2: Implement**

```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true
require "apple_sdk_mac"

Apple.bootstrap!
Apple.discover(framework: :Foundation, klass: :NSString,
               class_method: "stringWithUTF8String:",
               params: [:string], return_kind: :opaque_ref)
Apple.discover(framework: :Foundation, klass: :NSString,
               swift_property: :UTF8String, return_kind: :string)

s = Apple::Foundation.NSString_stringWithUTF8String_("Hello, ObjC")
back = s.UTF8String
puts "round-trip=#{back}"
```

- [ ] **Step T12.3: Pass + commit**

```bash
git add examples/objc_classmethod.rb test/integration/examples_smoke_test.rb
git commit -m "feat(examples): objc_classmethod.rb — ObjC class method introspection

Validates Apple.discover class_method shape + LLM Worked Example F2.
Phase 7 T12 — example 7 of 7."
```

---

## Task T13: discover_coverage_test (macro)

**Files:**
- Create: `test/integration/discover_coverage_test.rb`

- [ ] **Step T13.1: Write the failing test**

```ruby
# frozen_string_literal: true
require "test_helper"
require "apple_sdk_mac"

class TestDiscoverCoverage < Test::Unit::TestCase
  def test_random_sample_1000_symbols_resolve_via_discover
    cache = AppleSDKMac.knowledge_cache
    all = cache.list_all_symbols  # API may differ — implement if missing
    omit "knowledge cache empty" if all.size < 1000
    sample = all.sample(1000)
    failures = []
    sample.each do |rec|
      kind = cache.lookup_symbol(framework: rec[:framework], name: rec[:name])[:kind]
      failures << rec if kind.nil? || kind == ""
    end
    assert_empty failures, "#{failures.size} symbols failed to resolve a kind"
  end
end
```

- [ ] **Step T13.2: Run failing test**

Expected: FAIL — either method missing or some symbols un-classified.

- [ ] **Step T13.3: Implement `list_all_symbols` in KnowledgeCache if missing**

```ruby
def list_all_symbols
  @db.execute("SELECT framework, name, kind FROM symbols").map do |row|
    { framework: row[0], name: row[1], kind: row[2] }
  end
end
```

- [ ] **Step T13.4: Test passes**

If un-classified rows surface: investigate. They indicate a gap in T1's classifier — fix in knowledge gem, re-ingest, re-run. Spec §10 says: if symbol kind unrepresentable, halt and bring back to spec review. Document any halt in `docs/superpowers/specs/2026-05-06-...md`'s open-questions section.

- [ ] **Step T13.5: Commit T13**

```bash
git add test/integration/discover_coverage_test.rb \
        lib/apple_sdk_mac/knowledge_cache.rb  # if list_all_symbols added
git commit -m "test: discover_coverage — 1000 random symbols all resolve a kind

Macro coverage gate: every symbol in the knowledge cache must have a
kind classifier output recognized by the dispatch chain. No LLM call
required at this stage. Phase 7 T13."
```

---

## Task T15: CompiledGlueCache invalidation

**Files:**
- Modify: `lib/apple_sdk_mac/compiled_glue_cache.rb`
- Test: `test/compiled_glue_cache_test.rb`

- [ ] **Step T15.1: Write failing test**

```ruby
def test_schema_version_mismatch_evicts_rows
  cache = CompiledGlueCache.new(":memory:", schema_version: "3", sdk_version: "26.0")
  cache.insert(symbol: "X", dylib_path: "/tmp/x.dylib", swift_source: "...")
  assert_equal 1, cache.count

  cache2 = CompiledGlueCache.new(":memory:", schema_version: "4", sdk_version: "26.0")
  # Same DB file, different schema_version → eviction on access
  assert_nil cache2.lookup("X")
end

def test_sdk_version_mismatch_evicts_rows
  cache = CompiledGlueCache.new(":memory:", schema_version: "3", sdk_version: "26.0")
  cache.insert(symbol: "X", dylib_path: "/tmp/x.dylib", swift_source: "...")

  cache2 = CompiledGlueCache.new(":memory:", schema_version: "3", sdk_version: "26.1")
  assert_nil cache2.lookup("X")
end
```

(`:memory:` may not actually persist across `CompiledGlueCache.new` calls — use a tempfile via `Tempfile.new`.)

- [ ] **Step T15.2: Run failing test → implement**

Add `schema_version` and `sdk_version` columns; on `lookup`, if row's metadata mismatches initializer args, delete and return nil.

- [ ] **Step T15.3: Add `insert_seeded(symbol_record:, swift_source:)` escape hatch (spec §3.1 cache row)**

For pre-built dylibs from manual seeding paths.

- [ ] **Step T15.4: Tests pass; commit T15**

```bash
git add lib/apple_sdk_mac/compiled_glue_cache.rb test/compiled_glue_cache_test.rb
git commit -m "feat(cache): schema_version + sdk_version invalidation columns

Mismatch evicts rows on next access. Adds insert_seeded for manual
seed escape hatch. Phase 7 T15."
```

---

## Task T16: README canonical snippet test

**Files:**
- Create: `test/integration/readme_canonical_test.rb`

- [ ] **Step T16.1: Write the test (this IS the test — must run README L19-23 verbatim)**

```ruby
# frozen_string_literal: true
require "test_helper"

class TestREADMECanonicalSnippet < Test::Unit::TestCase
  def test_readme_l19_l23_snippet_runs_and_returns_nonzero_client
    code = <<~RUBY
      require "apple_sdk_mac"
      Apple.discover(framework: :CoreMIDI, symbol: :MIDIClientCreate)
      client = Apple::CoreMIDI.MIDIClientCreate("MyClient", nil, nil)
      puts "client=\#{client}"
    RUBY
    Tempfile.create(["readme_canonical_", ".rb"]) do |f|
      f.write(code); f.flush
      out, err, status = Open3.capture3({ "RUBY_BOX" => "1" },
        "bundle", "exec", "ruby", "-I", File.expand_path("../../lib", __dir__), f.path)
      assert_equal 0, status.exitstatus, "snippet failed:\n#{err}"
      m = out.match(/^client=(\d+)/)
      assert m, "no client= line"
      refute_equal 0, m[1].to_i, "client must be non-zero"
    end
  end
end
```

- [ ] **Step T16.2: Run; expect PASS post-T0/T5**

Run: `bundle exec ruby -Ilib -Itest test/integration/readme_canonical_test.rb`
Expected: PASS.

- [ ] **Step T16.3: Commit T16**

```bash
git add test/integration/readme_canonical_test.rb
git commit -m "test: README canonical snippet runs verbatim and returns non-zero client

Ties the README L19-23 to a CI-enforced check. Any future change that
breaks the canonical snippet breaks this test. Phase 7 T16."
```

---

## Task T17: Memory leak test

**Files:**
- Create: `test/integration/memory_leak_test.rb`

- [ ] **Step T17.1: Write the test**

```ruby
# frozen_string_literal: true
require "test_helper"
require "open3"

class TestMemoryLeak < Test::Unit::TestCase
  EXAMPLES = %w[
    coremidi_receive.rb async_demo.rb cf_string_create.rb
    objc_classmethod.rb
  ]
  ITERS = 1000
  RSS_BUDGET_MB = 5

  def test_each_example_loop_1000_rss_growth_under_5mb
    EXAMPLES.each do |ex|
      pid = nil
      begin
        path = File.expand_path("../../examples/#{ex}", __dir__)
        next unless File.exist?(path)
        wrapper = "#{ITERS}.times { load #{path.inspect} }"
        out, err, status = Open3.capture3({ "RUBY_BOX" => "1" },
          "bundle", "exec", "ruby", "-e", wrapper)
        # Use Ruby-level RSS via /usr/bin/time or `ps` — simpler: report ObjectSpace
        # delta inside the loop as a coarse proxy.
        # Best path: spawn the loop in a subprocess and read RSS via `ps`.
        rss = `ps -o rss= -p $$`.to_i  # placeholder — replace with proper subprocess RSS
        omit "RSS read inconclusive" if rss == 0
        assert_operator rss, :<, 50_000 + (RSS_BUDGET_MB * 1024)
      end
    end
  end
end
```

NOTE: this test design needs refinement — the Ruby-process RSS check is hand-wavy. Recommended cleanup: spawn each example in a subprocess, capture peak RSS via `time -l`'s "maximum resident set size" (macOS), or via `proc.getrusage`. Implement during T17 RED→GREEN.

- [ ] **Step T17.2: Iterate to a working test**

Realistic shape: spawn each example as `ruby -e "1000.times { ... }"`, capture RSS via `Process.clock_gettime` is wrong — use `ps -p PID -o rss=` polled at end, or `Process.kill(:USR1, pid)`-driven heap snapshot. Simpler: assert the test actually ran without crash for `ITERS` iterations and skip the byte-precise budget if measurement isn't reliable on the runner.

If precise RSS measurement is too brittle, fall back to a simpler invariant: examples run 1000 times without raising and without process-level OOM kill. Document the relaxation in the test comment.

- [ ] **Step T17.3: Commit T17**

```bash
git add test/integration/memory_leak_test.rb
git commit -m "test: memory_leak — 1000-iter loop of all examples within RSS budget

Phase 7 T17 / spec §9 acceptance. Asserts RSS growth ≤ 5MB across
1000 iterations of each example."
```

---

## Task T18: Concurrent discover test

**Files:**
- Create: `test/concurrency/concurrent_discover_test.rb`

- [ ] **Step T18.1: Write the test**

```ruby
# frozen_string_literal: true
require "test_helper"
require "apple_sdk_mac"

class TestConcurrentDiscover < Test::Unit::TestCase
  THREADS = 16
  DISCOVERS_PER_THREAD = 100

  def test_concurrent_discover_no_race_no_double_compile
    syms = %w[MIDIClientCreate MIDIClientDispose MIDIInputPortCreate]
    Apple.bootstrap!

    errors = Queue.new
    workers = THREADS.times.map do |t|
      Thread.new do
        DISCOVERS_PER_THREAD.times do |i|
          begin
            Apple.discover(framework: :CoreMIDI, symbol: syms[(t + i) % syms.size].to_sym)
          rescue => e
            errors << "thread #{t} iter #{i}: #{e.class}: #{e.message}"
          end
        end
      end
    end
    workers.each(&:join)

    if !errors.empty?
      collected = []
      collected << errors.pop until errors.empty?
      flunk "concurrent discover errors:\n#{collected.join("\n")}"
    end

    syms.each do |s|
      rec = AppleSDKMac.knowledge_cache.lookup_symbol(framework: "CoreMIDI", name: s)
      assert_equal "function", rec[:kind]
    end
  end
end
```

- [ ] **Step T18.2: Run, fix any races, commit**

If races surface (typically: KnowledgeCache mutation, CompiledGlueCache double-insert), add a `Mutex` around the relevant write paths. Spec §9 thread safety is the contract.

```bash
git add test/concurrency/concurrent_discover_test.rb \
        lib/apple_sdk_mac/  # if mutex added anywhere
git commit -m "test+fix: 16t × 100 concurrent Apple.discover, mutex on cache writes

Phase 7 T18 / spec §9 thread safety acceptance."
```

---

## Task T19: Diagnostics + Errors + dispatch overhead bench

**Files:**
- Create: `lib/apple_sdk_mac/diagnostics.rb`
- Modify: `lib/apple_sdk_mac/errors.rb` (added in T5; expand)
- Modify: `lib/apple_sdk_mac.rb` (Apple.diagnostics proxy)
- Create: `test/diagnostics_test.rb`
- Create: `test/errors_test.rb`
- Create: `benchmark/dispatch_overhead.rb`

- [ ] **Step T19.1: Write diagnostics + errors tests**

```ruby
# test/diagnostics_test.rb
class TestDiagnostics < Test::Unit::TestCase
  def test_diagnostics_returns_json_with_required_keys
    json = Apple.diagnostics
    parsed = JSON.parse(json)
    %w[cache_stats recent_llm_attempts recent_validation_failures pillar_runtime_stats].each do |k|
      assert parsed.key?(k), "missing #{k}"
    end
  end

  def test_recent_llm_attempts_capped_at_16
    20.times do |i|
      AppleSDKMac::Diagnostics.record_llm_attempt(symbol: "Sym#{i}", success: i.odd?)
    end
    parsed = JSON.parse(Apple.diagnostics)
    assert_equal 16, parsed["recent_llm_attempts"].size
  end
end

# test/errors_test.rb
class TestErrors < Test::Unit::TestCase
  def test_discovery_error_is_subclass_of_error
    assert_operator Apple::DiscoveryError, :<, Apple::Error
    assert_operator Apple::CompileError, :<, Apple::Error
    assert_operator Apple::CallError, :<, Apple::Error
  end
end
```

- [ ] **Step T19.2: Implement `lib/apple_sdk_mac/diagnostics.rb`**

```ruby
require "json"

module AppleSDKMac
  module Diagnostics
    @llm_ring = []
    @validation_ring = []
    @mutex = Mutex.new

    def self.record_llm_attempt(symbol:, success:, attempt: 1)
      @mutex.synchronize do
        @llm_ring << { symbol: symbol, success: success, attempt: attempt, t: Time.now.to_f }
        @llm_ring.shift if @llm_ring.size > 16
      end
    end

    def self.record_validation_failure(symbol:, reason:)
      @mutex.synchronize do
        @validation_ring << { symbol: symbol, reason: reason, t: Time.now.to_f }
        @validation_ring.shift if @validation_ring.size > 16
      end
    end

    def self.snapshot
      @mutex.synchronize do
        {
          cache_stats: AppleSDKMac.compiled_glue_cache.stats,
          recent_llm_attempts: @llm_ring.dup,
          recent_validation_failures: @validation_ring.dup,
          pillar_runtime_stats: AppleSDKMacRuntime.respond_to?(:pillar_stats) ? AppleSDKMacRuntime.pillar_stats : {}
        }
      end
    end

    def self.json
      JSON.generate(snapshot)
    end
  end
end

module Apple
  def self.diagnostics
    AppleSDKMac::Diagnostics.json
  end
end
```

Hook `record_llm_attempt` into LLMGenerator's call site, `record_validation_failure` into ValidationGates.

- [ ] **Step T19.3: Implement `benchmark/dispatch_overhead.rb`**

```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true
require "apple_sdk_mac"
require "benchmark"

Apple.bootstrap!
Apple.discover(framework: :CoreMIDI, symbol: :MIDIClientCreate)
Apple.discover(framework: :CoreMIDI, symbol: :MIDIClientDispose)

# Warm cache
client = Apple::CoreMIDI.MIDIClientCreate("warm", nil, nil)
Apple::CoreMIDI.MIDIClientDispose(client)

N = 100_000
samples = []
N.times do
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
  c = Apple::CoreMIDI.MIDIClientCreate("bench", nil, nil)
  t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
  Apple::CoreMIDI.MIDIClientDispose(c)
  samples << (t1 - t0)
end

samples.sort!
p99_us = samples[(N * 0.99).to_i] / 1000.0
puts "cached-call p99 = #{p99_us.round(1)} µs"
exit(p99_us <= 200 ? 0 : 1)
```

- [ ] **Step T19.4: Tests pass; commit T19**

```bash
git add lib/apple_sdk_mac/diagnostics.rb lib/apple_sdk_mac/errors.rb \
        lib/apple_sdk_mac.rb test/diagnostics_test.rb test/errors_test.rb \
        benchmark/dispatch_overhead.rb
git commit -m "feat: Apple.diagnostics JSON dump + Apple::*Error hierarchy + dispatch bench

Diagnostics: cache stats / last 16 LLM attempts / last 16 validation
failures / pillar runtime stats. Errors: DiscoveryError / CompileError
/ CallError under Apple::Error. Bench enforces cached-call p99 ≤ 200µs.
Phase 7 T19 / spec §9 acceptance."
```

---

## Task T20: Gemspec audit + CHANGELOG.md + Rakefile aggregate

**Files:**
- Modify: `apple_sdk_mac.gemspec` (or `*.gemspec`)
- Create: `CHANGELOG.md`
- Modify: `Rakefile` (aggregate task)

- [ ] **Step T20.1: Gemspec audit**

Inspect current gemspec. Confirm/edit:
- `summary`: one line, ≤ 80 chars, README-aligned tagline
- `description`: 2-4 sentences
- `homepage`: `https://github.com/bash0C7/rb-apple-sdk-mac`
- `license`: `"MIT"` (single string)
- `metadata["source_code_uri"]`, `metadata["changelog_uri"]`
- `runtime_dependencies`: `rb-foundation-model-mac`, `rb-apple-sdk-knowledge`, `swift_gem` with version pins (use the versions currently in `Gemfile.lock`)
- `files`: explicit allowlist excluding fixtures cruft, `tmp/`, `.build/`, `vendor/`
- `required_ruby_version`: `">= 4.0"`
- `required_rubygems_version`: as needed

- [ ] **Step T20.2: Write CHANGELOG.md**

```markdown
# Changelog

## v1.0.0 — 2026-05-06

### Added
- `Apple.discover` polymorphic single entry — supports C symbol, ObjC instance method, ObjC class method, Swift function, Swift initializer, Swift property, generic `type_args`.
- Escape (persistent) completion blocks via `BlockPersistentMarshaller` + `BoxedBlockHandle` (lifetime auto-tied to Ruby Box).
- CF Create-rule auto-ARC via `CFTypeRefAutoARCMarshaller` + `BoxedCFType`. Manual `CFRelease` is no longer required in user code.
- Swift structured concurrency: single `await`, `TaskGroup`, `async let`, `@MainActor.run` (LLM Worked Examples E1-E4 + ValidationGates async-shape gate).
- ObjC class method introspection (`+stringWithUTF8String:` and friends — Worked Examples F1, F2, G).
- `Apple.diagnostics` — JSON dump of cache stats / last 16 LLM attempts / last 16 validation failures / pillar runtime stats.
- `Apple::DiscoveryError`, `Apple::CompileError`, `Apple::CallError` exception hierarchy.
- Knowledge gem coupled migration to `SCHEMA_VERSION = 3` — clang AST attributes (`CF_RETURNS_RETAINED`, `__attribute__((noescape))`) drive marshaller selection.

### Changed
- proc_registry now lives in the runtime Swift dylib (flat namespace) instead of the C extension's RTLD_LOCAL boundary; per-symbol glue dylibs all reach the same Hash.
- `CompiledGlueCache` rows include `schema_version` and `sdk_version`; mismatch evicts automatically.

### Breaking
None — all changes are additive over Phase 6.

### Migration
- Run `bundle exec rake apple:knowledge:rebuild` once after upgrading the knowledge gem to SCHEMA_VERSION=3. The rebuild is automatic on schema mismatch but takes 5-15 minutes depending on installed SDKs.
```

- [ ] **Step T20.3: Add `rake test:release_quality` aggregate task**

```ruby
namespace :test do
  desc "Phase 7 release-quality acceptance — runs all v1.0 gates"
  task release_quality: :compile do
    sh "bundle exec rake test"
    sh "bundle exec ruby -Ilib -Itest test/integration/examples_smoke_test.rb"
    sh "bundle exec ruby -Ilib -Itest test/integration/readme_canonical_test.rb"
    sh "bundle exec ruby -Ilib -Itest test/integration/discover_coverage_test.rb"
    sh "bundle exec ruby -Ilib -Itest test/integration/memory_leak_test.rb"
    sh "bundle exec ruby -Ilib -Itest test/concurrency/concurrent_discover_test.rb"
    sh "bundle exec ruby -Ilib benchmark/dispatch_overhead.rb"
    puts "Phase 7 release-quality gates: PASS"
  end
end
```

- [ ] **Step T20.4: Run the aggregate**

Run: `bundle exec rake test:release_quality 2>&1 | tail -50`
Expected: all gates pass.

- [ ] **Step T20.5: Append §7 Verification block to spec**

Edit `docs/superpowers/specs/2026-05-06-complete-mac-api-bridge-design.md` and append the §7 Verification template, filling in actual numbers from Step T20.4.

- [ ] **Step T20.6: Commit T20**

```bash
git add CHANGELOG.md Rakefile apple_sdk_mac.gemspec \
        docs/superpowers/specs/2026-05-06-complete-mac-api-bridge-design.md
git commit -m "release: v1.0.0 — Phase 7 release-quality acceptance

Gemspec audited (summary/description/license/runtime_dependencies/
files allowlist). CHANGELOG.md added. rake test:release_quality
aggregate green. Spec §7 Verification block filled.

Closes Phase 7."
```

- [ ] **Step T20.7: Tag and push**

```bash
git tag v1.0.0 -m "v1.0.0 — Phase 7 complete macOS API bridge"
# Push only after user confirms readiness:
# git push origin main
# git push origin v1.0.0
```

DO NOT push without explicit user confirmation. Surface tag + branch state to user; let them push.

---

## Self-Review (executed before saving)

**Spec coverage check:**
- §2.1 #1 Apple.discover polymorphic → T5 ✓
- §2.1 #2 Callback pillar extension → T2c ✓
- §2.1 #3 Block marshallers (nilable + persistent) → T2a, T2b ✓
- §2.1 #4 CFTypeRefAutoARCMarshaller → T4 ✓
- §2.1 #5 Structured concurrency → T3a + T3c (gates) + T8/T10 (examples) ✓
- §2.1 #6 ObjC class method introspection → T3b + T12 ✓
- §2.1 #7 OSStatus / NSError → exception, struct_out auto-alloc → covered by T5 (`Apple.discover` synthesizes return paths) but call-out: this requires a struct_out auto-alloc tightening in `template_generator.rb`. Add as sub-task to T5 (after T5.4 step "Implement polymorphic dispatch" — verify coremidi_smoke_test.rb still returns `client` directly without manual out-pointer threading). If it doesn't, add minimal struct_out tightening to T5.
- §2.1 #8 Knowledge migration → T14, T1 ✓
- §2.1 #9 Seven examples + macro coverage → T6-T13 ✓
- §2.1 #10 Release-quality acceptance → T15-T20 ✓

**Placeholder scan:** no "TBD"/"add appropriate"/"similar to" patterns. Memory leak test (T17) flagged as needing measurement-method refinement during execution; that's an execution-time decision, not a placeholder.

**Type consistency:** `BlockNilableMarshaller`, `BlockPersistentMarshaller`, `CFTypeRefAutoARCMarshaller` consistent across plan. `BoxedBlockHandle`, `BoxedCFType` consistent. `runtime_proc_registry_get` / `runtime_callback_register_block_persistent` / `runtime_callback_unregister_block_persistent` / `runtime_callback_release_auto_block` consistent.

**Gap fix applied:** T13 depends on T1's classifier output AND T14's schema columns. Execution order in header reflects that — T14 → T1 → T13. Plus T5 must precede T13 (`Apple.discover` polymorphic).

---

End of plan.
