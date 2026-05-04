# Bug C — Template ↔ Runtime Integration Design

**Date:** 2026-05-05
**Scope:** rb-apple-sdk-mac (gem C) + rb-apple-sdk-knowledge (gem B)
**Status:** approved by user, ready for implementation plan

## Context

Bug A (gem C SwiftcInvoker `-I` for `AppleSDKMacRuntime`) and Bug B (gem B importer pipes `parameters_json`) landed and are verified end-to-end:

- DB now contains `parameters_json` for C functions (e.g. `MIDIClientCreate` has 4 typed parameters).
- Generated glue Swift includes the proper `import AppleSDKMacRuntime` chain and the swiftc invocation resolves it.

However, the gem C smoke test `test_create_client_and_dispose` still **omits** because the cached glue Swift (now non-empty due to Bug B) calls APIs that AppleSDKMacRuntime never implements:

| Called by template | Reality in `ext/apple_sdk_mac_runtime/Sources/AppleSDKMacRuntime/` |
|---|---|
| `Marshal.fromRubyString` / `fromRubyAny` / `fromRubyInt` / `fromRubyBool` | ❌ — Marshal only has `swiftString(fromCString:)` and `cString(fromSwift:)` |
| `Marshal.toRuby(...)` | ❌ |
| `ErrorBridge.rb_raise_via_runtime(.argumentError, ...)` | ❌ — only the `Kind` enum exists |
| `RefTable.retain(... as AnyObject)` for non-class typedefs | ❌ — RefTable enforces `AnyObject` |
| C-pointer → Swift type lowering for `void * _Nullable`, etc. | ❌ — `strip_pointer` produces invalid Swift |

The template was written against a **planned** runtime API surface that was never implemented. This spec replaces that surface with a simpler architecture rather than catching up.

## Goal

Make the template path of gem C produce Swift glue that:

1. Compiles successfully with `swiftc` against the real `AppleSDKMacRuntime` package and a CRuby-compatible link line.
2. Runs successfully when dlopened by the C ext, executing the underlying Apple SDK C function and returning a Ruby-visible result.
3. Handles error returns by raising a Ruby exception.

Success is measured by `test_create_client_and_dispose` flipping from omit to pass, plus the existing 47 tests remaining green.

## Non-goals

- Callbacks (`MIDINotifyProc` and friends): kind=`unsupported` → LLM fallback.
- Raw `void *` pointers other than nil-only: kind=`unsupported`.
- Variadic / generic / Swift async functions.
- Wrapping opaque scalar refs (`MIDIClientRef`) in a typed Ruby class. They flow as Ruby `Integer` end-to-end. (A future change can wrap them, with tests, when type safety becomes a real need.)
- Linux portability of the glue dylib (`-undefined dynamic_lookup` is macOS-only; the project is macOS-only).

## Architecture

### Layered responsibilities

```
gem B HeaderParser
  └─ clang AST → :parameters [
       { name, type, kind, is_out_param, nullability }
     ]   (richer parameters_json than today)

gem C template_generator
  └─ kind dispatch (5 supported + 1 unsupported)
     produces Swift glue that calls CRuby symbols directly
     via @_silgen_name; no Swift-side Marshal/ErrorBridge
     wrappers.

gem C glue dylib (per-symbol .dylib)
  └─ swiftc -I <Modules> -Xlinker -undefined -Xlinker dynamic_lookup
     CRuby symbols resolve at dlopen against the host process.

gem C AppleSDKMacRuntime Swift module
  └─ Marshal.swift: keeps swiftString/cString helpers (used by
     other parts of the runtime), no new VALUE-aware API.
  └─ ErrorBridge.swift: deleted.
  └─ RefTable.swift: kept as-is (used by other code paths;
     template path no longer touches it).

gem C C ext (apple_sdk_mac_runtime.c)
  └─ unchanged. No callback installation needed.
```

### ABI contract (unchanged)

`glue_fn_t = VALUE (*)(const VALUE *argv, int argc)`. On 64-bit CRuby this is `UInt (*)(UnsafePointer<UInt>, Int32)` in Swift. Already self-consistent. No ABI change.

### How `@_silgen_name` replaces the Marshal layer

The glue dylib is dlopened in the same process as CRuby. CRuby's symbols (`rb_string_value_cstr`, `rb_num2ll`, `rb_raise`, `rb_eRuntimeError`, `Qnil`, `Qfalse`, `Qtrue`) are already in the global symbol table.

Linking the glue dylib with `-Xlinker -undefined -Xlinker dynamic_lookup` defers symbol resolution to dlopen time, where the host process supplies them. The template emits `@_silgen_name("rb_*")` declarations in each glue Swift source so the symbols can be referenced from Swift.

This eliminates:
- The static callback table (no `runtime_install_callbacks`).
- The Swift `Marshal.fromRubyXXX` / `toRubyXXX` wrappers.
- The Swift `ErrorBridge.rb_raise_via_runtime` wrapper.

It introduces:
- A small block of `@_silgen_name` declarations at the top of every generated glue Swift file. This block is fixed, not parameter-dependent, and lives in `template_generator.rb`'s header constant.

## Kind set

5 supported + 1 catch-all. Direct, one-line dispatch in `template_generator.rb`.

| kind | Matches | from-Ruby (Swift expr) | to-Ruby (Swift expr) |
|---|---|---|---|
| `string` | `char *`, `const char *`, `CFStringRef`, `NSString *` | `String(cString: rb_string_value_cstr(&v))`, with a trailing `as CFString` iff qualType contains `CFString`, or `as NSString` iff qualType contains `NSString` | `rb_str_new_cstr(s)` (where `s` is `String`; CF/NS variants converted to `String` first) |
| `int` | `Int*`/`UInt*`/`SInt*`/`long`/`short` typedefs **except** names ending `Ref` | `rb_num2ll(argv[i])` (signed) / `rb_num2ull(argv[i])` (unsigned) | `rb_ll2inum(v)` / `rb_ull2inum(v)` |
| `bool` | `Bool`/`BOOL`/`_Bool` | `argv[i] != Qfalse && argv[i] != Qnil` | `v ? Qtrue : Qfalse` |
| `float` | `double`/`float`/`CGFloat` | `rb_num2dbl(argv[i])` | `rb_float_new(v)` |
| `opaque_ref` | typedef of integer with name ending `Ref` (e.g. `MIDIClientRef`, `CFStringRef` is `string` not this — explicit string match wins) | `Type(rb_num2ull(argv[i]))` for unsigned typedefs, `Type(rb_num2ll(argv[i]))` for signed; signedness is detected from the qualType (presence of `unsigned`/`UInt`/`UInt32`/`UInt64`) | `rb_ull2inum(UInt64(v))` for unsigned, `rb_ll2inum(Int64(v))` for signed |
| `unsupported` | callbacks, raw `void *`, variadic, generic, Swift async, anything not above | template returns `nil` from `generate(...)` → existing LLM fallback path |

Direct/orthogonal flag: `is_out_param: bool`.

### Out-param convention

A parameter is marked `is_out_param: true` if and only if **both**:
1. Its qualType contains `*` (it is a pointer, syntactically).
2. Either it is the last pointer-typed parameter in the function, or its name starts with `out`.

The template emits, for an out-param of pointee type `T`:
```swift
var outRef: T = T()    // T is concrete (Int32/UInt32/etc.); never void
```
After the C call, the function's return value is computed from `outRef` (using the `to-Ruby` conversion for the parameter's `kind`), not from the C function's return value. The C function's return value is treated as a status code: if non-zero and the function's return type is `OSStatus`/`Int32`/`SInt32`, raise.

Functions with multiple `Type *` parameters where more than one looks like an out-param are **left to LLM fallback** in this design (kind=`unsupported`).

### Status / error handling

If the C function's return type is a signed/unsigned integer typedef NOT classified as `opaque_ref` (i.e. `OSStatus`, `Int32`, `UInt32`, `int`, `kern_return_t`, etc.) and the value is non-zero, the glue raises. `bool`/`float`/`opaque_ref`/`string` returns are passed through to-Ruby unchanged with no status check.

```swift
rb_raise(rb_eRuntimeError, "OSStatus %d")  // status interpolated
```

If the C function's return type is non-integer (e.g. `void`, an opaque ref directly returned), the glue returns the converted value via `to-Ruby` of its return-type kind.

CRuby's `rb_raise` is `__attribute__((noreturn))`; the Swift declaration uses `-> Never`.

### Cache invalidation

`compute_glue_id` extends from:
```ruby
Digest::SHA256.hexdigest("#{framework}|#{symbol[:name]}|#{symbol[:signature]}")
```
to:
```ruby
Digest::SHA256.hexdigest("#{framework}|#{symbol[:name]}|#{symbol[:signature]}|#{symbol[:parameters_json]}")
```

so any change in the structured parameter metadata produces a new `glue_id` and a fresh compile. Old glue dylibs on disk become orphans; cleaning them is out of scope (a separate `rake apple:cache:clean` task can be added later, not part of this spec).

## File-level changes

### gem B (rb-apple-sdk-knowledge)

- `lib/rb_apple_sdk_knowledge/importer/header_parser.rb` — add a `classify_kind(qualType, desugared)` helper, an `out_param?` heuristic, an `nullability(node)` extractor, and emit `:kind`, `:is_out_param`, `:nullability` alongside existing `:name`/`:type` in `function_parameters`.
- `test/test_header_parser.rb` — add structured-kind tests for each kind plus out-param detection.
- `test/fixtures/MiniHeader.h` — extend with cases covering each kind (already covers `int`-style + out-param via `MiniCreate`; add a `Bool` and a `double` parameter to a new function).

DB rebuild: required, ~4 hours, after gem B changes commit.

### gem C (rb-apple-sdk-mac)

- `lib/apple_sdk_mac/glue_compiler/template_generator.rb` — full rewrite of the `generate_c_function` path. Drops `parse_params`/`load_param`/`out_param?`/`strip_pointer` regex helpers. New flow:
  1. Read `sym[:parameters_json]` as the structured array (with `kind`, `is_out_param`, `nullability`).
  2. If any parameter has `kind == "unsupported"`, return nil (LLM fallback).
  3. Emit a fixed `@_silgen_name` header block.
  4. For each input parameter (`!is_out_param`), emit a one-line `let name = <from-ruby>(argv[i])` per the kind table.
  5. For at most one out-parameter, emit `var outRef: T = T()`.
  6. Emit the C function call.
  7. Emit status check + `rb_raise` if integer return ≠ 0.
  8. Emit `return <to-ruby>(...)` per return kind / out-param kind.

- `lib/apple_sdk_mac/glue_compiler/swiftc_invoker.rb` — append `-Xlinker -undefined -Xlinker dynamic_lookup` to the swiftc args.

- `lib/apple_sdk_mac/glue_compiler.rb` — `compute_glue_id` includes parameters_json.

- `ext/apple_sdk_mac_runtime/Sources/AppleSDKMacRuntime/ErrorBridge.swift` — delete.
- `ext/apple_sdk_mac_runtime/Sources/AppleSDKMacRuntime/Marshal.swift` — keep as-is (no API additions). If during implementation it is verified to have zero callers, deletion is acceptable as a follow-up cleanup; not required by this spec.
- `lib/apple_sdk_mac/glue_compiler/template_generator.rb` — must NOT reference `Marshal.from*`/`to*` or `ErrorBridge.rb_raise_via_runtime`. (Hard requirement; assert via test.)

- `test/glue_compiler/template_generator_test.rb` (new) — per-kind output assertions on a fixed input.

- `test/swiftc_invoker_test.rb` — add a test that `-undefined dynamic_lookup` appears in the argv.

- `test/glue_compiler_test.rb` — `StubSwiftc#compile` already accepts `module_search_paths:` after the regression fix; no further change needed.

- `test/integration/coremidi_smoke_test.rb` — kept as-is. It is the final acceptance test.

### gem C C ext

No changes. The existing `apple_sdk_mac_runtime.c` continues to bind into the runtime as before. Glue dylibs resolve `rb_*` symbols against the host CRuby at dlopen time.

## Testing strategy

TDD per layer. Each step is a RED commit + GREEN commit.

- **gem B**: kind classifier and out-param detection get unit tests on AST fixtures (no real Apple SDK needed). Full integration test for `MIDIClientCreate` runs after DB rebuild.
- **gem C template_generator**: per-kind unit tests pin the exact emitted Swift for each kind, plus a "no `Marshal.from*`/`ErrorBridge` references" guard test.
- **gem C SwiftcInvoker**: existing fake-swiftc pattern verifies the new `-undefined dynamic_lookup` arg pair appears in invocation.
- **gem C glue_compiler**: cache-invalidation test (different parameters_json → different glue_id).
- **E2E**: `test_create_client_and_dispose` flips omit → pass.

## Risks and mitigations

- **`@_silgen_name` is undocumented**: stable in Swift 6.x, used widely in Apple's own swift-corelibs and by macOS gem authors. Mitigation: if it ever breaks, fall back to a clang module map for ruby.h. Code change is localized to the header block in `template_generator.rb`.
- **CRuby ABI shifts**: `Qnil = 8`, `Qfalse = 0`, `Qtrue = 20`, and the `rb_*` function signatures used here are part of CRuby's stable C ABI. The minimum-supported Ruby version is already pinned (≥ 4.0). When bumping CRuby majors, run the gem's test suite and recompile glue cache.
- **Heuristic misclassification**: `*Ref` typedef-name heuristic can mis-route a non-opaque integer typedef. Mitigation: misclassification produces invalid Swift → swiftc compile error → existing LLM fallback path. No silent corruption.
- **`-undefined dynamic_lookup` and library-evolution warnings**: known cosmetic warning under `-enable-library-evolution`. Suppress only if it pollutes test output; not a functional issue.

## Out of scope

- Wrapping opaque refs in Ruby classes (lookup/unwrap on dispatch).
- Variadic / async / Swift generic templates.
- Multi-out-param convention.
- Linux glue dylib portability.
- `rake apple:cache:clean` task for orphaned glue dylibs after schema changes.
- Any change to the LLM fallback path (preserved as the escape valve).
