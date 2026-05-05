# Unified Marshalling and Callback Pillar Design

**Date:** 2026-05-05
**Scope:** rb-apple-sdk-mac (gem C) + rb-apple-sdk-knowledge (gem K), cross-repo
**Status:** approved by user, ready for implementation plan
**Supersedes (partial):** `2026-05-05-llm-fallback-prompt-alignment-design.md` — Out-of-scope clauses for struct in/out, callback marshalling, and multi-out-param are lifted; LLM fallback path itself remains the long-tail bridge for symbols outside this design's kind taxonomy.

## Context

`rb-apple-sdk-mac` README declares the library goal as: *"Call any public Apple framework API from Ruby with no pre-declarations."* The integration smoke test T10 (`test_create_client_and_dispose`, `Apple::CoreMIDI.MIDIClientCreate("MyClient", nil, nil)` + `MIDIClientDispose`) is currently omitted because `MIDIClientCreate` carries a nullable callback parameter (`MIDINotifyProc`) and a nullable `void *` (`notifyRefCon`), both of which the upstream knowledge parser tags as `kind=unsupported`. The template generator escapes any symbol with even one `unsupported` parameter to the LLM fallback, which has not been able to produce compileable glue for these typed-pointer / callback shapes (verified 2026-05-05: 0 of 6 retries reached `dlopen`-ready state).

The fix is **not** another LLM-prompt iteration. The upstream knowledge gem has the structural information required to classify these parameters precisely; the template generator can emit deterministic Swift for them. The same architectural lift unlocks struct in/out marshalling (required for `MIDISend(MIDIPacketList)` and CG-family APIs), multi-out-param (`AudioComponentInstanceNew`-class symbols), variadic functions (`NSLog`-class), and Ruby-Block-as-callback bridging (MIDI input subscribers, AVFoundation completion handlers).

This spec consolidates those lifts into one cross-repo change so the kind taxonomy, schema, and Marshaller abstraction stay coherent.

## Goal

Bring the library to **practical-application-ready** state, defined as:

1. README usage example runs end-to-end: `Apple::CoreMIDI.MIDIClientCreate("MyClient", nil, nil)` returns a client, `MIDIClientDispose(client)` releases it.
2. A non-trivial MIDI send path runs: build `MIDIPacketList` from Ruby, call `MIDISend(port, dest, pktlist)`.
3. A non-trivial MIDI receive path runs: pass a Ruby `Proc` as `MIDINotifyProc`, observe it being invoked when MIDI state changes.
4. The kind taxonomy is closed in the sense that any C function symbol from the supported macOS 26+ frameworks lands in exactly one of: deterministic template path, deterministic template path with Callback-pillar dispatch, or `unsupported` LLM fallback (the LLM path is preserved for genuinely exotic shapes — Swift-only generics, C++ templates, deprecated APIs).

## Non-goals (true Out of scope)

- **C++ template / namespace syntactic features** — Apple frameworks expose all public surface through C, Obj-C, or Swift; calling C++ symbols from Ruby is not a real-world need.
- **Symbols deprecated since macOS 26** — knowledge gem skips them at import; gem C never sees them.

Everything else is in scope, including: self-referential structs (cycle-detected, depth-1 escape), variadic functions, Swift-only API surface, callback non-nil bridging, struct ↔ struct nesting, `nullability="unspecified"` policy, and LLM prompt header sync.

## Architecture (cross-repo data flow)

```
[clang AST dump]
  ↓ HeaderParser (gem K)
  ├─ FunctionDecl  → parameters[] {name, type, kind, is_out_param, nullability}
  └─ RecordDecl    → fields[]    {name, type, kind} ← NEW: walk FieldDecl inner
  ↓ Importer (gem K)
  ↓ Store#insert_symbol — parameters_json + fields_json (NEW column, ALTER TABLE)
  ↓
[sdk_knowledge_<v>.sqlite] (schema_version 2)
  ↓ KnowledgeCache#lookup_symbol → Hash includes :fields_json
  ↓
[TemplateGenerator (gem C)]
  ├─ Marshaller selection by kind ─────────┐
  │  (string / int / bool / float /        │
  │   opaque_ref / callback_nilable /      │
  │   callback_non_nil / void_ptr_nilable /│
  │   struct_in / struct_out /             │
  │   variadic_args)                       │
  ├─ in_loads = marshallers.map(&:load_in) │
  ├─ call_args = marshallers.map(&:call_arg)
  ├─ out_inits + out_addrs (multi)         │
  ├─ to_ruby_expr (single ret or hash)     │
  └─ unsupported residue ──→ LLMGenerator (unchanged dispatch loop)
  ↓
[ext/apple_sdk_mac_runtime] (Swift package)
  ├─ existing pillars (Marshal, ARC, ...) ─ UNCHANGED
  └─ CallbackPillar (NEW Swift module)
     - signature-set pre-generated trampolines (~50 covering MIDI / CF / AV)
     - register(rubyBlock:, signature:) → CallbackHandle{ fnptr, releaser }
     - GVL-aware invoke from any thread
     - GC-pin Ruby Block until unregister
```

Dependency direction: gem K → gem C → runtime ext. Knowledge gem stays Ruby-only and contains no `apple_sdk_mac` references. The Marshaller pattern in gem C is a closed-world dispatcher; adding a new kind requires a new Marshaller class and a knowledge-gem classifier tweak, nothing else.

## Common abstraction — Marshaller pattern

Each parameter kind is realized as a `Marshaller` object with a fixed protocol:

```ruby
class Marshaller
  def initialize(param, index, ctx); end  # ctx = { framework:, knowledge_cache:, struct_visited: Set }
  def in_load;     end  # Swift snippet: argv[i] → Swift binding (or nil for out-only)
  def call_arg;    end  # Swift snippet: argument at the C call site
  def out_init;    end  # Swift snippet: var declaration before the call (or nil)
  def out_addr;    end  # Swift snippet: address-of expression at the call (or nil)
  def out_to_ruby; end  # Swift snippet: post-call out value → Ruby VALUE (or nil)
end
```

The template generator becomes a thin orchestrator:

```ruby
def generate(framework:, symbol:, glue_id:)
  ctx = { framework:, knowledge_cache: @kc, struct_visited: Set.new }
  marshallers = parse_params(symbol[:parameters_json]).map.with_index do |p, i|
    Marshaller.for(p, i, ctx) || (return nil)  # nil → unsupported, escape to LLM
  end
  build_swift(framework, symbol, glue_id, marshallers)
end
```

Adding `variadic_args` later means a new `VariadicMarshaller` class and a dispatch entry in `Marshaller.for`. No change to `build_swift`. This is what "kind 単位で SDK 全体に効く γ 路線" looks like under a single abstraction.

The legacy flat-`case`-statement implementation in `template_generator.rb` is replaced by this object-oriented dispatch as part of the GREEN commits.

## Knowledge gem (`rb-apple-sdk-knowledge`) changes

### Schema migration

`lib/rb_apple_sdk_knowledge/store.rb`:
- Bump `SCHEMA_VERSION` 1 → 2.
- Add `fields_json TEXT` column to `symbols` table.
- `migrate!` gains an idempotent `ensure_column!` helper that runs `ALTER TABLE ADD COLUMN` if the column is missing. Existing rows get NULL for `fields_json`; full population requires a `rake apple:knowledge:rebuild`.
- `insert_symbol` accepts `fields_json:` kwarg.

```ruby
def migrate!
  @db.execute_batch(SCHEMA_SQL)
  ensure_column!("symbols", "fields_json", "TEXT")
  @db.execute("INSERT OR REPLACE INTO schema_meta (key, value) VALUES (?, ?)",
              ["schema_version", SCHEMA_VERSION.to_s])
end

def ensure_column!(table, col, type)
  cols = @db.execute("PRAGMA table_info(#{table})").map { |r| r[1] }
  return if cols.include?(col)
  @db.execute("ALTER TABLE #{table} ADD COLUMN #{col} #{type}")
end
```

### Header parser extension

`lib/rb_apple_sdk_knowledge/importer/header_parser.rb`:
- `RecordDecl` branch walks `node["inner"]` selecting `FieldDecl`, builds `fields[]` with `{name, type, kind}` per field. `kind` reuses `Kind.classify_kind` recursively so nested struct fields land in the same taxonomy.
- `TypedefDecl` for struct typedefs leaves `fields: nil`; consumers resolve typedef → original `RecordDecl` by `name` in the importer reconciliation pass.

### Kind classifier extension

`lib/rb_apple_sdk_knowledge/importer/kind.rb`:
- `Kind.classify_kind` signature gains a third arg: `nullability`. Default `"unspecified"` to preserve callers.
- New rules:
  - `nullability ∈ {"nullable", "unspecified"}` AND `qual_type =~ /\bvoid\s*\*/` → `"void_ptr_nilable"`.
  - `nullability ∈ {"nullable", "unspecified"}` AND function-pointer typedef → `"callback_nilable"`.
  - `nullability == "nonnull"` AND function-pointer typedef → `"callback_non_nil"`.
  - struct typedef (non-Ref) → `"struct_in"` for in-params and `"struct_out"` for out-params (out-param flag handed in via `out_param?` per existing path).
  - Variadic marker `"..."` in qual_type → `"variadic_args"` (single synthetic param at tail).
- The `unspecified-treated-as-nullable` policy is conservative: legacy headers that pre-date `_Nullable` annotations get the nilable Marshaller, which always handles the `Qnil` case correctly and only fails-loud on a non-nil pass-through (existing rb_raise behavior).

### Importer hookup

`lib/rb_apple_sdk_knowledge/importer.rb`:
- struct symbol insert flushes `fields: JSON.dump(fields)` into `fields_json:`.
- function symbol insert is unchanged in shape; the new kinds simply propagate from the parser.

### Reclassifier

`lib/rb_apple_sdk_knowledge/reclassifier.rb` runs as a post-import pass and is updated to recognize the new kinds (so backfill-from-existing-DB scenarios don't silently fall back to `unsupported`). Its existing structure (per-symbol re-walk of parameters_json) is preserved.

## Gem C (`rb-apple-sdk-mac`) changes

### `KnowledgeCache#lookup_symbol`

Add `s.fields_json` to the SELECT, surface as `:fields_json` in the returned Hash. `list_framework_symbols` is unchanged.

### `TemplateGenerator` restructure

Split into:
- `lib/apple_sdk_mac/glue_compiler/template_generator.rb` — orchestrator, `generate`, `parse_params`, `build_swift`.
- `lib/apple_sdk_mac/glue_compiler/marshallers.rb` — Marshaller base + per-kind subclasses.

Existing kinds (`string`, `int`, `bool`, `float`, `opaque_ref`) become Marshaller classes preserving today's Swift output verbatim. New kinds add new subclasses. The legacy `case`-statement code is removed (not duplicated) once the Marshaller path is green for all existing test cases.

`HEADER` constant is extended:

```ruby
HEADER = <<~SWIFT.freeze
  # ... existing rb_string_value_cstr, rb_str_new_cstr, rb_num2ll, rb_num2ull,
  # rb_ll2inum, rb_ull2inum, rb_num2dbl, rb_float_new, rb_raise, rb_eRuntimeError,
  # Qfalse/Qnil/Qtrue ...

  @_silgen_name("rb_hash_new")
  func rb_hash_new() -> UInt
  @_silgen_name("rb_hash_aref")
  func rb_hash_aref(_ hash: UInt, _ key: UInt) -> UInt
  @_silgen_name("rb_hash_aset")
  func rb_hash_aset(_ hash: UInt, _ key: UInt, _ val: UInt) -> UInt
  @_silgen_name("rb_block_given_p")
  func rb_block_given_p() -> Int32
  @_silgen_name("rb_block_proc")
  func rb_block_proc() -> UInt
SWIFT
```

`LLMGenerator::INSTRUCTIONS` interpolates `HEADER` already, so the new symbols flow through automatically. WORKED_EXAMPLE_STRUCT_IN and WORKED_EXAMPLE_OUT_HASH are added (alongside the existing INT_IN_STRING_OUT and STRING_IN_STATUS_OUT) so the LLM fallback for residual `unsupported` symbols can also produce hash returns.

### LLM prompt sync

LLMGenerator gets two new worked examples (struct_in, multi-out hash). Section-1 rules add: rule 11 (struct in/out via field-by-field hash), rule 12 (variadic via withVaList). Existing rules 9/10 (callback / void*) stay; the prompt's `else`-branch in rule 9 is updated to point at `AppleSDKMacRuntime.CallbackPillar.register` instead of unconditional `rb_raise` — symmetric with the template-generator path.

## Kind taxonomy (full)

| kind | Marshaller class | template handles? |
|---|---|---|
| `string` | `StringMarshaller` | yes |
| `int` | `IntMarshaller` | yes |
| `bool` | `BoolMarshaller` | yes |
| `float` | `FloatMarshaller` | yes |
| `opaque_ref` | `OpaqueRefMarshaller` | yes |
| `callback_nilable` | `CallbackNilableMarshaller` | yes (nil branch + Callback pillar non-nil branch) |
| `callback_non_nil` | `CallbackNonNilMarshaller` | yes (Callback pillar mandatory) |
| `void_ptr_nilable` | `VoidPtrNilableMarshaller` | yes |
| `struct_in` | `StructInMarshaller` | yes (recursive for nested fields, cycle detection) |
| `struct_out` | `StructOutMarshaller` | yes (recursive) |
| `variadic_args` | `VariadicMarshaller` | yes |
| `unsupported` | — | no, escape to LLM |

## Swift code generation patterns

Per-kind output samples. `<i>` = parameter index, `<name>` = Ruby parameter name.

### `string` (CFString cast preserved)

```swift
var v<i> = argv[<i>]
let <name> = String(cString: rb_string_value_cstr(&v<i>)) as CFString
```

### `callback_nilable`

```swift
let <name>: <CallbackType>?
var <name>_handle: AppleSDKMacRuntime.CallbackPillar.Handle? = nil
if argv[<i>] == Qnil {
    <name> = nil
} else {
    <name>_handle = AppleSDKMacRuntime.CallbackPillar.register(
        rubyBlock: argv[<i>], signature: .<sigToken>
    )
    <name> = <name>_handle!.fnptr as <CallbackType>
}
defer { <name>_handle?.unregister() }
```

`<sigToken>` is determined at template-emit time from the typedef name (`MIDINotifyProc` → `.midiNotifyProc`); see Callback pillar section below.

### `callback_non_nil`

Same as nilable's `else` branch, no nil guard. If `argv[<i>] == Qnil`, the Callback pillar's `register` raises a Ruby `TypeError` at runtime (defensive, since the C signature requires non-nil).

### `void_ptr_nilable`

```swift
let <name>: UnsafeMutableRawPointer?
if argv[<i>] == Qnil {
    <name> = nil
} else {
    <name> = UnsafeMutableRawPointer(bitPattern: Int(rb_num2ll(argv[<i>])))
}
```

### `struct_in` (with nesting)

Resolved by template-time recursion. For a top-level `MIDIPacketList`-shape struct with fields `numPackets: UInt32`, `packet: MIDIPacket` (and `MIDIPacket` itself has `timeStamp: UInt64`, `length: UInt16`, `data: [UInt8]`):

```swift
let <name>_h = argv[<i>]
var <name>_struct = <StructType>()
<name>_struct.numPackets = UInt32(rb_num2ull(rb_hash_aref(<name>_h, rb_str_new_cstr("numPackets"))))
// Nested struct unfolded depth-1
let <name>_packet_h = rb_hash_aref(<name>_h, rb_str_new_cstr("packet"))
<name>_struct.packet.timeStamp = UInt64(rb_num2ull(rb_hash_aref(<name>_packet_h, rb_str_new_cstr("timeStamp"))))
<name>_struct.packet.length = UInt16(rb_num2ull(rb_hash_aref(<name>_packet_h, rb_str_new_cstr("length"))))
// ... fixed-size byte array fields → packed UInt8 string in Ruby, byte-loop on Swift side
```

Cycle detection: `ctx[:struct_visited]` set tracks the stack of struct typedef names. If a field's struct type is already on the stack, the Marshaller returns `nil` from `for`, escaping the entire symbol to LLM (rare, e.g. linked-list head structs).

Argument site: `withUnsafePointer(to: &<name>_struct) { <name>_ptr in /* call */ }` so the call expression is wrapped (one extra `withUnsafePointer` per struct-in param at the outermost call).

### `struct_out`

```swift
var <name>_struct = <StructType>()
let status = <Symbol>(<args>..., &<name>_struct)
if status != 0 { rb_raise(rb_eRuntimeError, "OSStatus") }
let <name>_h = rb_hash_new()
rb_hash_aset(<name>_h, rb_str_new_cstr("field1"), <to_ruby field1>)
// ... per field ...
return <name>_h
```

### `variadic_args`

```swift
let varStart = <fixedArgc>
var cVarArgs: [CVarArg] = []
for k in varStart..<Int(argc) {
    cVarArgs.append(rubyValueToCVarArg(argv[k]))  // helper from runtime ext
}
let result = withVaList(cVarArgs) { va in
    return <Symbol>(<fixed args>..., va)
}
```

### Multi-out-param

`build_swift` collects `out_init` Swift snippets from all out-param Marshallers in declaration order, builds the call with `&<name>_struct` references, then composes the return:

- 0 out-params: existing return-value path.
- 1 out-param: existing single-value return.
- ≥2 out-params: `let h = rb_hash_new(); rb_hash_aset(h, rb_str_new_cstr("<name1>"), <to_ruby>); ... ; return h`.

If the symbol has both a meaningful return value (non-OSStatus) AND out-params, the return value is added under key `"return"`.

## Callback pillar implementation

Lives in `ext/apple_sdk_mac_runtime/Sources/CallbackPillar/` (new directory inside the existing Swift package).

### Approach: signature-set pre-generated trampolines (recommended)

A code-generation rake task (`rake runtime:codegen_callback_pillar`) reads a curated `callback_signatures.yml` and emits one Swift trampoline function + one signature-token enum case per signature. Initial set covers the high-frequency signatures from CoreMIDI / CoreFoundation / AVFoundation / AudioToolbox (≈50 signatures). New frameworks add entries to the YAML. Adding a signature is a 5-line YAML edit + regen + commit; no hand-written Swift.

```yaml
# ext/apple_sdk_mac_runtime/callback_signatures.yml
- token: midiNotifyProc
  swift_type: MIDINotifyProc
  c_signature: "void (*)(const MIDINotification *, void *)"
  args:
    - { name: msg, swift: "UnsafePointer<MIDINotification>" }
    - { name: refcon, swift: "UnsafeMutableRawPointer?" }
  return: void

- token: cfAllocatorAllocate
  swift_type: CFAllocatorAllocateCallBack
  c_signature: "void *(*)(CFIndex, CFOptionFlags, void *)"
  args:
    - { name: size, swift: "CFIndex" }
    - { name: hint, swift: "CFOptionFlags" }
    - { name: info, swift: "UnsafeMutableRawPointer?" }
  return: "UnsafeMutableRawPointer?"

# ... initial ~50 entries
```

Generated Swift (single file `CallbackPillarGenerated.swift`):

```swift
public extension CallbackPillar {
    enum Signature {
        case midiNotifyProc
        case cfAllocatorAllocate
        // ... one case per yaml entry
    }

    static func register(rubyBlock: UInt, signature: Signature) -> Handle {
        switch signature {
        case .midiNotifyProc:
            return registerMidiNotifyProc(rubyBlock)
        case .cfAllocatorAllocate:
            return registerCfAllocatorAllocate(rubyBlock)
        // ...
        }
    }

    private static func registerMidiNotifyProc(_ rubyBlock: UInt) -> Handle {
        let slot = ctxStore.alloc(rubyBlock: rubyBlock)
        let trampoline: MIDINotifyProc = { (msg, refcon) in
            let s = Unmanaged<Slot>.fromOpaque(refcon!).takeUnretainedValue()
            withGVL {
                rb_funcall(s.rubyBlock, rb_intern("call"), 2,
                           wrapMIDINotificationPtr(msg),
                           wrapVoidPtr(refcon))
            }
        }
        return Handle(fnptr: unsafeBitCast(trampoline, to: UnsafeRawPointer.self),
                      slot: slot)
    }
    // ... per-signature register* funcs
}
```

### Hand-written core (`CallbackPillar.swift`)

```swift
public enum CallbackPillar {
    public struct Handle {
        let fnptr: UnsafeRawPointer
        let slot: Slot
        public func unregister() { ctxStore.free(slot) }
    }

    static let ctxStore = SlotStore()  // thread-safe slot allocator
}

final class Slot {
    let rubyBlock: UInt  // GC-pinned via rb_gc_register_address
    init(rubyBlock: UInt) {
        self.rubyBlock = rubyBlock
        rb_gc_register_address(addressOf(rubyBlock))
    }
    deinit {
        rb_gc_unregister_address(addressOf(rubyBlock))
    }
}

func withGVL<T>(_ body: () -> T) -> T {
    // calls rb_thread_call_with_gvl when invoked off the Ruby thread,
    // direct otherwise (callback pillar inspects current thread)
}
```

### CRuby integration

- Ruby Block is captured as a `VALUE` (`UInt`) at `register` time and pinned via `rb_gc_register_address` until `unregister`.
- Trampoline is invoked from any C thread; if not the Ruby thread, `rb_thread_call_with_gvl` brings the call back onto the Ruby VM.
- Callback args are wrapped per signature via small helpers (`wrapMIDINotificationPtr`, `wrapVoidPtr`, etc.) that produce Ruby `VALUE`s — these wrappers are expanded as the codegen target evolves.
- Reentrancy: nested callback (Ruby Block → C call → another callback firing) is supported because GVL is held across the whole stack.

### Why pre-generated rather than libffi

- macOS `dlopen` of arbitrary `libffi` from a sandboxed gem is brittle (signing, hardened runtime).
- Apple's framework callback signatures are a finite, slowly-evolving set. Auditing all signatures manually has security and stability benefits.
- The codegen approach is one rake task + a yaml schema. libffi adds ~2000 lines of Swift binding for marginal benefit.
- libffi fallback can be added later under the same `Signature` enum (a `.dynamic(spec)` case backed by libffi for one-off symbols), without touching the consumer template_generator code.

## Multi-out-param generalization

Already covered in Architecture and Swift gen patterns. Two implementation notes:

- The `out_params.length > 1` guard in current `template_generator.rb:42` is removed.
- `build_swift` switches the return-statement strategy on the count of out-params and the presence of a non-status return value, per the table in the Swift-gen-patterns section.

## Testing strategy (t-wada style, RED → GREEN per commit)

### Gem K tests

`test/importer/header_parser_test.rb`:
1. RED `test_recorddecl_emits_fields_with_kinds` — fixture mini-header with one struct, assert `fields[]` shape.
2. RED `test_recorddecl_emits_nested_struct_fields` — fixture with `struct A { struct B inner; }`.
3. RED `test_typedef_struct_resolution_links_to_recorddecl` — `typedef struct Foo Foo;` typedef points to `Foo`'s fields via importer reconciliation.

`test/importer/kind_test.rb`:
4. RED `test_classifies_nullable_void_ptr_as_void_ptr_nilable`.
5. RED `test_classifies_nullable_callback_typedef_as_callback_nilable`.
6. RED `test_classifies_nonnull_callback_typedef_as_callback_non_nil`.
7. RED `test_classifies_unspecified_void_ptr_as_void_ptr_nilable` (unspecified → nullable policy).
8. RED `test_classifies_variadic_marker`.

`test/store_test.rb`:
9. RED `test_migrate_adds_fields_json_column_idempotently` — schema_version 1 fixture DB → migrate → column present, second migrate no-op.

GREEN commits implement the parser + classifier + store changes.

### Gem C tests

`test/template_generator_test.rb`:
10. RED `test_marshaller_dispatch_routes_existing_kinds` — every existing kind still produces byte-identical Swift after refactor.
11. RED `test_callback_nilable_emits_callback_pillar_register_in_else`.
12. RED `test_callback_non_nil_emits_callback_pillar_register_unconditionally`.
13. RED `test_void_ptr_nilable_emits_bitpattern`.
14. RED `test_struct_in_emits_field_by_field_hash_aref`.
15. RED `test_struct_in_handles_nested_depth_1`.
16. RED `test_struct_in_cycle_detection_returns_nil` (linked-list shape escapes to LLM).
17. RED `test_struct_out_emits_hash_new_aset_per_field`.
18. RED `test_multi_out_param_returns_hash_with_named_keys`.
19. RED `test_variadic_args_emits_with_va_list`.
20. RED `test_midiclientcreate_endtoend_swift_shape` — full integration with real parameters_json + fields_json.
21. RED `test_midisend_struct_in_endtoend_swift_shape`.
22. RED `test_unsupported_residue_returns_nil_for_llm_fallback`.

`test/llm_generator_test.rb`:
23. RED `test_instructions_embed_extended_header` — `rb_hash_new` / `rb_hash_aref` / `rb_hash_aset` present.
24. RED `test_instructions_have_struct_in_worked_example`.
25. RED `test_instructions_callback_else_branch_uses_callback_pillar`.

GREEN commits implement Marshaller classes + restructure + LLM prompt sync.

### Smoke tests

`test/integration/coremidi_smoke_test.rb`:
26. RED `test_create_client_and_dispose` — currently omitted; assert PASS after implementation.
27. RED `test_send_packet` — build MIDIClient → MIDIOutputPort → ad-hoc dest endpoint → `MIDIPacketList.new(...)` from Ruby Hash → `MIDISend` returns 0.
28. RED `test_receive_notification` — register Ruby Proc as `MIDINotifyProc`, trigger a state change (e.g. create another client in subprocess), observe Proc invocation via shared file or Queue; tolerates 5s timeout → omit if Foundation Model is offline (this test is not strictly required for acceptance criteria 1+2).

GREEN: each smoke goes from omit/fail to PASS as the implementation lands.

### E2E verification

After all gem K + gem C commits land:
1. In gem K: `bundle exec rake apple:knowledge:rebuild`.
2. In gem C: `sqlite3 ~/.cache/rb-apple-sdk-mac/26.2/glue.sqlite "DELETE FROM compile_history;"` (full wipe — cache invalidated by HEADER change anyway).
3. In gem C: `screen -dmS bug-c-unified-verify-20260505 ...` running `coremidi_smoke_test.rb`.
4. After DONE: sentinel: inspect `compile_history`, expect every MIDI symbol with `generator='template'` and `error_stage IS NULL`.
5. Append "Verification" section to this spec recording outcome and any residue. Commit.

## File-level changes summary

| Repo | File | Change |
|---|---|---|
| gem K | `lib/rb_apple_sdk_knowledge/store.rb` | SCHEMA_VERSION=2, ensure_column!, fields_json kwarg |
| gem K | `lib/rb_apple_sdk_knowledge/importer/header_parser.rb` | RecordDecl walks FieldDecl, emits fields[] |
| gem K | `lib/rb_apple_sdk_knowledge/importer/kind.rb` | classify_kind takes nullability, emits new kinds |
| gem K | `lib/rb_apple_sdk_knowledge/importer.rb` | passes fields_json on struct insert |
| gem K | `lib/rb_apple_sdk_knowledge/reclassifier.rb` | recognizes new kinds in re-walk |
| gem K | `data/sdk_knowledge_26.2.sqlite` | rebuilt; committed |
| gem K | tests (×9) | RED + GREEN |
| gem C | `lib/apple_sdk_mac/glue_compiler/template_generator.rb` | Marshaller orchestrator, HEADER extension |
| gem C | `lib/apple_sdk_mac/glue_compiler/marshallers.rb` | NEW — Marshaller base + 11 subclasses |
| gem C | `lib/apple_sdk_mac/knowledge_cache.rb` | fields_json in lookup_symbol |
| gem C | `lib/apple_sdk_mac/glue_compiler/llm_generator.rb` | new worked examples, rules 11/12, callback pillar in rule 9 else |
| gem C | `ext/apple_sdk_mac_runtime/Sources/CallbackPillar/CallbackPillar.swift` | NEW — core Slot/Handle/withGVL |
| gem C | `ext/apple_sdk_mac_runtime/Sources/CallbackPillar/CallbackPillarGenerated.swift` | NEW — codegen output, ~50 trampolines |
| gem C | `ext/apple_sdk_mac_runtime/callback_signatures.yml` | NEW — signature catalog |
| gem C | `Rakefile` | NEW task `runtime:codegen_callback_pillar` |
| gem C | tests (×16+3) | RED + GREEN |
| gem C | `test/integration/coremidi_smoke_test.rb` | new tests + T10 flip |

## Acceptance criteria

The spec is acceptance-complete when, with no manual prompts during the run:

1. README example `Apple::CoreMIDI.MIDIClientCreate("MyClient", nil, nil)` returns a non-nil opaque handle and the corresponding `MIDIClientDispose(client)` returns 0.
2. `MIDISend(port, dest, MIDIPacketList.new(...))` returns 0 from a Ruby-constructed packet list.
3. Both repos pass their full test suites (`bundle exec rake test`) with 0 failures, 0 errors. Omissions limited to: `test_live_ollama_returns_some_swift` (LLM-online gating) and `test_receive_notification` (timing-sensitive integration).
4. `compile_history` contains zero rows with `generator='llm'` for any CoreMIDI symbol referenced by the smoke tests.

## Risks and mitigations

- **`fields_json` schema migration on shared DBs.** ALTER TABLE ADD COLUMN is non-locking on SQLite for nullable columns. Existing consumers that don't read `fields_json` keep working. Mitigation: SCHEMA_VERSION bump signals to consumers that a rebuild produces richer data.
- **CallbackPillar pre-gen signature gaps.** A new framework's callback that isn't in `callback_signatures.yml` falls through to LLM fallback. Mitigation: signature-add is a 5-line YAML edit; in practice, a CI nightly that imports the macOS SDK and reports unknown signatures keeps the catalog fresh (not in this spec; ops follow-up).
- **Ruby Block GC pinning leak.** If a caller forgets to `unregister` a non-nil callback handle, the Block stays pinned. Mitigation: `Handle` exposes `defer { unregister() }` in the Swift glue (already in the template emit), and the runtime's Slot `deinit` is a backstop.
- **Variadic callable correctness.** Ruby `Object` → CVarArg coverage is incomplete for some types. Mitigation: `rubyValueToCVarArg` raises with a helpful message on unsupported argument kinds; only printf-class symbols actually exercise this.
- **Swift function-pointer trampoline ABI on macOS 26.** Hardened-runtime + library validation may reject some `unsafeBitCast` patterns. Mitigation: `@convention(c)` closures are first-class in Swift 6.3 and have stable ABI; the runtime ext is signed with the gem's identity.

## References

- Predecessor spec: `2026-05-05-llm-fallback-prompt-alignment-design.md` — prompt-only fix that this design supersedes.
- Predecessor spec: `2026-05-05-bug-c-template-runtime-integration-design.md` — Bug C template runtime integration.
- Plan: see `docs/superpowers/plans/2026-05-05-unified-marshalling-and-callback-pillar.md` (to be written).
- README usage: `~/dev/src/github.com/bash0C7/rb-apple-sdk-mac/README.md` Usage section.
