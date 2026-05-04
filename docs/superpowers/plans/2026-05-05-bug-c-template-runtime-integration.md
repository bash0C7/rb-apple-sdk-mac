# Bug C — Template ↔ Runtime Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make gem C `template_generator` produce compilable, runnable Swift glue for Apple SDK C functions by replacing the unimplemented `Marshal.fromRubyXXX` / `ErrorBridge.rb_raise_via_runtime` wrapper layer with direct CRuby symbol references via `@_silgen_name` + dlopen with `-undefined dynamic_lookup`.

**Architecture:** Two coordinated gems. gem B (`rb-apple-sdk-knowledge`) HeaderParser emits clang-AST-derived kind metadata (`string` / `int` / `bool` / `float` / `opaque_ref` / `unsupported` + `is_out_param` flag) inside `parameters_json`. gem C (`rb-apple-sdk-mac`) `template_generator` dispatches on kind and emits Swift glue that calls CRuby (`rb_string_value_cstr`, `rb_num2ll`, `rb_raise`, `Qnil`, etc.) directly via `@_silgen_name`. The Swift `Marshal` / `ErrorBridge` wrapper layer is removed.

**Tech Stack:** Ruby (test-unit, clang AST JSON), Swift 6.3+ (`@c`, `@_silgen_name`), SQLite (knowledge DB), swiftc with `-undefined dynamic_lookup`, dlopen/dlsym at glue load time.

**Spec:** `docs/superpowers/specs/2026-05-05-bug-c-template-runtime-integration-design.md`

---

## File Structure

### gem B (`rb-apple-sdk-knowledge`, ~/dev/src/github.com/bash0C7/rb-apple-sdk-knowledge)

- Modify `lib/rb_apple_sdk_knowledge/importer/header_parser.rb` — add `classify_kind`, `out_param?`, `nullability_of`; extend `function_parameters` to emit `:kind`, `:is_out_param`, `:nullability`.
- Modify `test/test_header_parser.rb` — add per-kind tests + out-param tests + unsupported-fallback test.
- Modify `test/fixtures/MiniHeader.h` — add a `Bool` arg, a `double` arg, a `MiniSomethingRef`-style typedef use, and a `void *` use.

### gem C (`rb-apple-sdk-mac`, ~/dev/src/github.com/bash0C7/rb-apple-sdk-mac)

- Modify `lib/apple_sdk_mac/glue_compiler.rb` — `compute_glue_id` includes `parameters_json`.
- Modify `lib/apple_sdk_mac/glue_compiler/swiftc_invoker.rb` — append `-Xlinker -undefined -Xlinker dynamic_lookup`.
- Replace `lib/apple_sdk_mac/glue_compiler/template_generator.rb` — full rewrite of `generate_c_function` path; new `KIND_DISPATCH` table, `@_silgen_name` HEADER, kind-driven emission.
- Delete `ext/apple_sdk_mac_runtime/Sources/AppleSDKMacRuntime/ErrorBridge.swift`.
- Add `test/glue_compiler/template_generator_test.rb` — per-kind output tests + guard test.
- Modify `test/swiftc_invoker_test.rb` — add `-undefined dynamic_lookup` test.
- Modify `test/glue_compiler_test.rb` — add cache-invalidation test.

### DB

- `~/dev/src/github.com/bash0C7/rb-apple-sdk-knowledge/data/sdk_knowledge_26.2.sqlite` — to be deleted and rebuilt (~4 hours) after gem B changes are merged.

---

## Task 1: gem B — Extend MiniHeader.h fixture for new kinds

**Files:**
- Modify: `~/dev/src/github.com/bash0C7/rb-apple-sdk-knowledge/test/fixtures/MiniHeader.h`

- [ ] **Step 1: Edit MiniHeader.h to add new test cases**

Append to `MiniHeader.h` before `#endif`:

```c
typedef uint32_t MiniNodeRef;

double MiniGetRatio(MiniClientRef client);
_Bool MiniIsActive(MiniClientRef client, _Bool checkPower);
MiniStatus MiniWithCallback(MiniCallback cb, void *userData);
MiniStatus MiniMakeNode(MiniClientRef client, MiniNodeRef *outNode);
```

This adds: a `double` return (float kind), a `_Bool` parameter and return (bool kind), a non-last-pointer `void *` (unsupported), a callback-typed parameter (unsupported), and a second opaque ref typedef (`MiniNodeRef`).

- [ ] **Step 2: Verify fixture compiles via clang AST dump**

Run:
```bash
cd ~/dev/src/github.com/bash0C7/rb-apple-sdk-knowledge
xcrun clang -Xclang -ast-dump=json -fsyntax-only -x c test/fixtures/MiniHeader.h | head -3
```
Expected: a `TranslationUnitDecl` JSON line, no parse errors.

- [ ] **Step 3: Commit**

```bash
git add test/fixtures/MiniHeader.h
git commit -m "test: extend MiniHeader.h with bool/float/callback/void*/second-ref cases"
```

---

## Task 2: gem B — Add `:kind` field to FunctionDecl emission (string / int)

**Files:**
- Modify: `~/dev/src/github.com/bash0C7/rb-apple-sdk-knowledge/lib/rb_apple_sdk_knowledge/importer/header_parser.rb`
- Modify: `~/dev/src/github.com/bash0C7/rb-apple-sdk-knowledge/test/test_header_parser.rb`

- [ ] **Step 1: Write failing test for `string` and `int` kinds (RED)**

Append to `test/test_header_parser.rb`:

```ruby
def test_classifies_string_param
  fn = @symbols.find { |s| s[:name] == "MiniCreate" && s[:kind] == "function" }
  name_param = fn[:parameters].find { |p| p[:name] == "name" }
  assert_equal "string", name_param[:kind]
end

def test_classifies_int_param
  fn = @symbols.find { |s| s[:name] == "MiniDispose" && s[:kind] == "function" }
  client_param = fn[:parameters].find { |p| p[:name] == "client" }
  # MiniClientRef = struct *, name ends in Ref, becomes opaque_ref later;
  # for THIS step we only assert kind is set (not nil).
  assert_not_nil client_param[:kind]
end
```

- [ ] **Step 2: Run RED test, verify failure**

```bash
cd ~/dev/src/github.com/bash0C7/rb-apple-sdk-knowledge
bundle exec ruby -Ilib -Itest test/test_header_parser.rb -n test_classifies_string_param
```
Expected: NoMethodError or assertion failure on `:kind` being nil.

- [ ] **Step 3: Add `classify_kind` helper and emit `:kind` (GREEN)**

In `lib/rb_apple_sdk_knowledge/importer/header_parser.rb`, replace `function_parameters` with:

```ruby
def function_parameters(node)
  params = (node["inner"] || []).select { |i| i["kind"] == "ParmVarDecl" }
  pointer_params = params.select { |p| (p.dig("type", "qualType") || "").include?("*") }
  last_pointer = pointer_params.last

  params.each_with_index.map do |p, i|
    qual_type = p.dig("type", "qualType") || ""
    name = p["name"] || "_arg#{i}"
    {
      name: name,
      type: qual_type,
      kind: classify_kind(qual_type),
      is_out_param: out_param?(qual_type, name, p == last_pointer),
      nullability: nullability_of(qual_type)
    }
  end
end

def classify_kind(qual_type)
  return "string" if qual_type =~ /\b(CFStringRef|NSString\s*\*|char\s*\*|const\s+char\s*\*)/
  return "bool"   if qual_type =~ /\b(_Bool|Bool|BOOL)\b/
  return "float"  if qual_type =~ /\b(double|float|CGFloat)\b/
  if qual_type =~ /\b(?:U?Int(?:8|16|32|64)?|SInt(?:8|16|32|64)?|long|short|unsigned|signed|uint(?:8|16|32|64)_t|int(?:8|16|32|64)_t|OSStatus|kern_return_t)\b/
    return "opaque_ref" if qual_type =~ /\b\w+Ref\b/
    return "int"
  end
  "unsupported"
end

def out_param?(qual_type, name, is_last_pointer)
  return false unless qual_type.include?("*")
  is_last_pointer || name.start_with?("out")
end

def nullability_of(qual_type)
  return "nonnull"  if qual_type.include?("_Nonnull")
  return "nullable" if qual_type.include?("_Nullable")
  "unspecified"
end
```

- [ ] **Step 4: Run tests, verify GREEN**

```bash
cd ~/dev/src/github.com/bash0C7/rb-apple-sdk-knowledge
bundle exec ruby -Ilib -Itest test/test_header_parser.rb
```
Expected: 0 failures, 0 errors.

- [ ] **Step 5: Commit**

```bash
git add lib/rb_apple_sdk_knowledge/importer/header_parser.rb test/test_header_parser.rb
git commit -m "feat: add kind classifier (string/int/bool/float/opaque_ref/unsupported) to HeaderParser"
```

---

## Task 3: gem B — Lock down per-kind classification with explicit assertions

**Files:**
- Modify: `~/dev/src/github.com/bash0C7/rb-apple-sdk-knowledge/test/test_header_parser.rb`

- [ ] **Step 1: Write failing tests covering all kinds (RED)**

Append to `test/test_header_parser.rb`:

```ruby
def test_classifies_bool_param
  fn = @symbols.find { |s| s[:name] == "MiniIsActive" && s[:kind] == "function" }
  bool_param = fn[:parameters].find { |p| p[:name] == "checkPower" }
  assert_equal "bool", bool_param[:kind]
end

def test_classifies_float_return_function
  # Float kind shows up on the parameters; here MiniIsActive's BOOL-like return
  # is not exposed via :parameters. Use MiniGetRatio, whose only param is
  # MiniClientRef (opaque_ref).
  fn = @symbols.find { |s| s[:name] == "MiniGetRatio" && s[:kind] == "function" }
  client = fn[:parameters].find { |p| p[:name] == "client" }
  assert_equal "opaque_ref", client[:kind]
end

def test_classifies_opaque_ref_for_ref_typedef
  fn = @symbols.find { |s| s[:name] == "MiniDispose" && s[:kind] == "function" }
  client = fn[:parameters].find { |p| p[:name] == "client" }
  assert_equal "opaque_ref", client[:kind]
end

def test_classifies_void_pointer_as_unsupported
  fn = @symbols.find { |s| s[:name] == "MiniWithCallback" && s[:kind] == "function" }
  user_data = fn[:parameters].find { |p| p[:name] == "userData" }
  assert_equal "unsupported", user_data[:kind]
end

def test_classifies_callback_typedef_as_unsupported
  fn = @symbols.find { |s| s[:name] == "MiniWithCallback" && s[:kind] == "function" }
  cb = fn[:parameters].find { |p| p[:name] == "cb" }
  assert_equal "unsupported", cb[:kind]
end
```

- [ ] **Step 2: Run RED tests, observe which kinds fail**

```bash
cd ~/dev/src/github.com/bash0C7/rb-apple-sdk-knowledge
bundle exec ruby -Ilib -Itest test/test_header_parser.rb 2>&1 | grep -E "Failure|Error"
```
Expected: callback typedef test fails (current heuristic doesn't detect function-pointer typedefs as unsupported when they appear via typedef alias resolution).

- [ ] **Step 3: Refine `classify_kind` to detect callback / function-pointer (GREEN)**

In `lib/rb_apple_sdk_knowledge/importer/header_parser.rb#classify_kind`, before the integer branch, add:

```ruby
# Function-pointer typedefs in clang JSON resolve to the underlying type via
# desugaredQualType; if the desugared form contains a parenthesized signature
# it is a function pointer.
desugared = qual_type # qualType in our caller already contains the typedef name;
                     # the desugared form must be passed in. Update signature:
```

Actually the caller passes only `qual_type`. Update `classify_kind` to also accept `desugared_qual_type`:

```ruby
def classify_kind(qual_type, desugared = qual_type)
  return "unsupported" if desugared.include?("(") && desugared.include?(")")  # function pointer
  return "string" if qual_type =~ /\b(CFStringRef|NSString\s*\*|char\s*\*|const\s+char\s*\*)/
  return "bool"   if qual_type =~ /\b(_Bool|Bool|BOOL)\b/
  return "float"  if qual_type =~ /\b(double|float|CGFloat)\b/
  if qual_type =~ /\b(?:U?Int(?:8|16|32|64)?|SInt(?:8|16|32|64)?|long|short|unsigned|signed|uint(?:8|16|32|64)_t|int(?:8|16|32|64)_t|OSStatus|kern_return_t)\b/
    return "opaque_ref" if qual_type =~ /\b\w+Ref\b/
    return "int"
  end
  return "unsupported" if qual_type =~ /\bvoid\s*\*/
  "unsupported"
end
```

And in `function_parameters`, pass desugared:
```ruby
qual_type = p.dig("type", "qualType") || ""
desugared = p.dig("type", "desugaredQualType") || qual_type
# ...
kind: classify_kind(qual_type, desugared),
```

- [ ] **Step 4: Run tests, verify all GREEN**

```bash
cd ~/dev/src/github.com/bash0C7/rb-apple-sdk-knowledge
bundle exec ruby -Ilib -Itest test/test_header_parser.rb
```
Expected: all kind tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/rb_apple_sdk_knowledge/importer/header_parser.rb test/test_header_parser.rb
git commit -m "feat: classify function-pointer typedefs and void* as unsupported"
```

---

## Task 4: gem B — Out-param detection

**Files:**
- Modify: `~/dev/src/github.com/bash0C7/rb-apple-sdk-knowledge/test/test_header_parser.rb`

- [ ] **Step 1: Write failing test for out-param detection (RED)**

Append to `test/test_header_parser.rb`:

```ruby
def test_detects_out_param_via_last_pointer
  fn = @symbols.find { |s| s[:name] == "MiniCreate" && s[:kind] == "function" }
  out = fn[:parameters].find { |p| p[:name] == "outClient" }
  in_  = fn[:parameters].find { |p| p[:name] == "name" }
  assert_equal true,  out[:is_out_param]
  assert_equal false, in_[:is_out_param]
end

def test_detects_out_param_for_make_node
  fn = @symbols.find { |s| s[:name] == "MiniMakeNode" && s[:kind] == "function" }
  out = fn[:parameters].find { |p| p[:name] == "outNode" }
  client = fn[:parameters].find { |p| p[:name] == "client" }
  assert_equal true,  out[:is_out_param]
  assert_equal false, client[:is_out_param]
end
```

- [ ] **Step 2: Run, verify GREEN**

The `out_param?` helper added in Task 2 already implements this heuristic. The fixture already has `MiniCreate(name, outClient)` and `MiniMakeNode(client, outNode)`.

```bash
cd ~/dev/src/github.com/bash0C7/rb-apple-sdk-knowledge
bundle exec ruby -Ilib -Itest test/test_header_parser.rb
```
Expected: both out-param tests pass without further code changes (they are the second-half of the helper that already shipped). If they fail, fix `out_param?` to handle the heuristic correctly.

- [ ] **Step 3: Commit**

```bash
git add test/test_header_parser.rb
git commit -m "test: pin out-param detection (last-pointer + outX-name heuristic)"
```

---

## Task 5: gem C — Cache invalidation via parameters_json in glue_id hash

**Files:**
- Modify: `~/dev/src/github.com/bash0C7/rb-apple-sdk-mac/lib/apple_sdk_mac/glue_compiler.rb`
- Modify: `~/dev/src/github.com/bash0C7/rb-apple-sdk-mac/test/glue_compiler_test.rb`

- [ ] **Step 1: Write failing test for cache invalidation (RED)**

Append to `test/glue_compiler_test.rb`:

```ruby
def test_glue_id_changes_when_parameters_json_changes
  Dir.mktmpdir do |dir|
    cache = AppleSDKMac::CompiledGlueCache.open(dir, sdk_version: "26.0")
    compiler = AppleSDKMac::GlueCompiler.new(
      cache: cache, runtime_dylib_path: "/dev/null",
      swiftc_invoker: StubSwiftc.new
    )
    sym1 = { name: "F", signature: "void F(int)", parameters_json: '[{"name":"x","kind":"int"}]' }
    sym2 = { name: "F", signature: "void F(int)", parameters_json: '[{"name":"y","kind":"int"}]' }

    id1 = compiler.send(:compute_glue_id, "X", sym1)
    id2 = compiler.send(:compute_glue_id, "X", sym2)
    assert_not_equal id1, id2,
      "compute_glue_id must include parameters_json so cached glue invalidates when metadata shape changes"
  end
end
```

- [ ] **Step 2: Run RED**

```bash
cd ~/dev/src/github.com/bash0C7/rb-apple-sdk-mac
bash -c '. ~/.swiftly/env.sh && bundle exec ruby -Ilib -Itest test/glue_compiler_test.rb -n test_glue_id_changes_when_parameters_json_changes'
```
Expected: assertion failure (current hash ignores `parameters_json`).

- [ ] **Step 3: Update compute_glue_id (GREEN)**

In `lib/apple_sdk_mac/glue_compiler.rb`:

```ruby
def compute_glue_id(framework, symbol)
  Digest::SHA256.hexdigest(
    "#{framework}|#{symbol[:name]}|#{symbol[:signature]}|#{symbol[:parameters_json]}"
  )[0, 16]
end
```

- [ ] **Step 4: Run, verify GREEN**

```bash
cd ~/dev/src/github.com/bash0C7/rb-apple-sdk-mac
bash -c '. ~/.swiftly/env.sh && bundle exec ruby -Ilib -Itest test/glue_compiler_test.rb'
```

- [ ] **Step 5: Commit**

```bash
git add lib/apple_sdk_mac/glue_compiler.rb test/glue_compiler_test.rb
git commit -m "feat: include parameters_json in glue_id hash for cache invalidation"
```

---

## Task 6: gem C — SwiftcInvoker passes -undefined dynamic_lookup

**Files:**
- Modify: `~/dev/src/github.com/bash0C7/rb-apple-sdk-mac/lib/apple_sdk_mac/glue_compiler/swiftc_invoker.rb`
- Modify: `~/dev/src/github.com/bash0C7/rb-apple-sdk-mac/test/swiftc_invoker_test.rb`

- [ ] **Step 1: Write failing test (RED)**

Append to `test/swiftc_invoker_test.rb`:

```ruby
def test_passes_undefined_dynamic_lookup
  Dir.mktmpdir do |dir|
    fake = File.join(dir, "fake-swiftc")
    log = File.join(dir, "argv.log")
    File.write(fake, <<~SH)
      #!/bin/sh
      printf '%s\\0' "$@" > #{log}
      exit 0
    SH
    File.chmod(0o755, fake)
    src = File.join(dir, "x.swift"); File.write(src, "")
    dylib = File.join(dir, "x.dylib")

    AppleSDKMac::GlueCompiler::SwiftcInvoker.new(swiftc: fake).compile(
      source_path: src, dylib_path: dylib
    )
    argv = File.read(log).split("\0")
    pairs = argv.each_cons(3).to_a
    assert(pairs.any? { |a, b, c| a == "-Xlinker" && b == "-undefined" } &&
           argv.each_cons(2).any? { |a, b| a == "-Xlinker" && b == "dynamic_lookup" },
           "expected -Xlinker -undefined -Xlinker dynamic_lookup, got: #{argv.inspect}")
  end
end
```

- [ ] **Step 2: Run RED**

```bash
cd ~/dev/src/github.com/bash0C7/rb-apple-sdk-mac
bash -c '. ~/.swiftly/env.sh && bundle exec ruby -Ilib -Itest test/swiftc_invoker_test.rb -n test_passes_undefined_dynamic_lookup'
```
Expected: assertion failure.

- [ ] **Step 3: Append flag to args (GREEN)**

In `lib/apple_sdk_mac/glue_compiler/swiftc_invoker.rb#compile`, before `args << source_path`:

```ruby
args << "-Xlinker" << "-undefined" << "-Xlinker" << "dynamic_lookup"
args << source_path
```

- [ ] **Step 4: Run, verify GREEN**

```bash
cd ~/dev/src/github.com/bash0C7/rb-apple-sdk-mac
bash -c '. ~/.swiftly/env.sh && bundle exec ruby -Ilib -Itest test/swiftc_invoker_test.rb'
```

- [ ] **Step 5: Commit**

```bash
git add lib/apple_sdk_mac/glue_compiler/swiftc_invoker.rb test/swiftc_invoker_test.rb
git commit -m "feat: link glue dylib with -undefined dynamic_lookup for CRuby symbol deferred resolution"
```

---

## Task 7: gem C — template_generator full rewrite (kind-driven)

**Files:**
- Replace: `~/dev/src/github.com/bash0C7/rb-apple-sdk-mac/lib/apple_sdk_mac/glue_compiler/template_generator.rb`
- Add: `~/dev/src/github.com/bash0C7/rb-apple-sdk-mac/test/glue_compiler/template_generator_test.rb`

- [ ] **Step 1: Write per-kind output tests + guard test (RED)**

Create `test/glue_compiler/template_generator_test.rb`:

```ruby
# frozen_string_literal: true
require "test_helper"
require "json"
require "apple_sdk_mac/glue_compiler/template_generator"

class TestTemplateGenerator < Test::Unit::TestCase
  def gen
    AppleSDKMac::GlueCompiler::TemplateGenerator.new
  end

  def sym(name:, kind: "function", abi: "c", signature:, parameters:)
    { name: name, kind: kind, abi: abi, signature: signature,
      parameters_json: JSON.generate(parameters) }
  end

  def test_returns_nil_for_unsupported_kind
    s = sym(name: "F", signature: "void F(void *p)",
            parameters: [{ name: "p", type: "void *", kind: "unsupported", is_out_param: false }])
    assert_nil gen.generate(framework: "X", symbol: s, glue_id: "abc")
  end

  def test_emits_silgen_name_header
    s = sym(name: "F", signature: "void F(int x)",
            parameters: [{ name: "x", type: "int", kind: "int", is_out_param: false }])
    out = gen.generate(framework: "Foundation", symbol: s, glue_id: "abc")
    assert_match(/@_silgen_name\("rb_num2ll"\)/, out)
    assert_match(/@_silgen_name\("rb_raise"\)/, out)
    assert_match(/@_silgen_name\("rb_str_new_cstr"\)/, out)
  end

  def test_emits_string_kind_with_cfstring_cast
    s = sym(name: "F", signature: "void F(CFStringRef _Nonnull s)",
            parameters: [{ name: "s", type: "CFStringRef _Nonnull", kind: "string",
                           is_out_param: false, nullability: "nonnull" }])
    out = gen.generate(framework: "Foundation", symbol: s, glue_id: "abc")
    assert_match(/let s = String\(cString: rb_string_value_cstr\(&v0\)\) as CFString/, out)
  end

  def test_emits_int_kind_using_rb_num2ll
    s = sym(name: "F", signature: "void F(int x)",
            parameters: [{ name: "x", type: "int", kind: "int", is_out_param: false }])
    out = gen.generate(framework: "Foundation", symbol: s, glue_id: "abc")
    assert_match(/let x: Int64 = rb_num2ll\(argv\[0\]\)/, out)
  end

  def test_emits_bool_kind
    s = sym(name: "F", signature: "void F(_Bool b)",
            parameters: [{ name: "b", type: "_Bool", kind: "bool", is_out_param: false }])
    out = gen.generate(framework: "Foundation", symbol: s, glue_id: "abc")
    assert_match(/let b: Bool = \(argv\[0\] != Qfalse && argv\[0\] != Qnil\)/, out)
  end

  def test_emits_float_kind
    s = sym(name: "F", signature: "void F(double d)",
            parameters: [{ name: "d", type: "double", kind: "float", is_out_param: false }])
    out = gen.generate(framework: "Foundation", symbol: s, glue_id: "abc")
    assert_match(/let d: Double = rb_num2dbl\(argv\[0\]\)/, out)
  end

  def test_emits_opaque_ref_kind_in
    s = sym(name: "F", signature: "void F(MIDIClientRef c)",
            parameters: [{ name: "c", type: "MIDIClientRef", kind: "opaque_ref", is_out_param: false }])
    out = gen.generate(framework: "CoreMIDI", symbol: s, glue_id: "abc")
    assert_match(/let c = MIDIClientRef\(rb_num2ull\(argv\[0\]\)\)/, out)
  end

  def test_emits_out_param_and_status_check
    s = sym(name: "MIDIClientCreate",
            signature: "OSStatus MIDIClientCreate(CFStringRef _Nonnull n, MIDIClientRef *_Nonnull o)",
            parameters: [
              { name: "n", type: "CFStringRef _Nonnull", kind: "string", is_out_param: false },
              { name: "o", type: "MIDIClientRef *", kind: "opaque_ref", is_out_param: true }
            ])
    out = gen.generate(framework: "CoreMIDI", symbol: s, glue_id: "abc")
    assert_match(/var outRef: MIDIClientRef = MIDIClientRef\(\)/, out)
    assert_match(/let status = MIDIClientCreate\(n, &outRef\)/, out)
    assert_match(/if status != 0 \{ rb_raise\(rb_eRuntimeError/, out)
    assert_match(/return rb_ull2inum\(UInt64\(outRef\)\)/, out)
  end

  def test_emits_status_check_for_status_int_return_without_outparam
    # MIDIClientDispose returns OSStatus, takes single opaque_ref input, no out-param.
    s = sym(name: "MIDIClientDispose",
            signature: "OSStatus MIDIClientDispose(MIDIClientRef client)",
            parameters: [{ name: "client", type: "MIDIClientRef", kind: "opaque_ref", is_out_param: false }])
    out = gen.generate(framework: "CoreMIDI", symbol: s, glue_id: "abc")
    assert_match(/let result = MIDIClientDispose\(client\)/, out)
    assert_match(/if result != 0 \{ rb_raise\(rb_eRuntimeError/, out)
    assert_match(/return Qnil/, out)
  end

  def test_does_not_reference_marshal_or_errorbridge
    s = sym(name: "F", signature: "void F(int x)",
            parameters: [{ name: "x", type: "int", kind: "int", is_out_param: false }])
    out = gen.generate(framework: "Foundation", symbol: s, glue_id: "abc")
    assert_not_match(/Marshal\.from/, out)
    assert_not_match(/Marshal\.toRuby/, out)
    assert_not_match(/ErrorBridge\.rb_raise_via_runtime/, out)
  end
end
```

- [ ] **Step 2: Run RED**

```bash
cd ~/dev/src/github.com/bash0C7/rb-apple-sdk-mac
bash -c '. ~/.swiftly/env.sh && bundle exec ruby -Ilib -Itest test/glue_compiler/template_generator_test.rb 2>&1' | tail -20
```
Expected: most or all tests fail (current generator emits `Marshal.from*` etc.).

- [ ] **Step 3: Replace `template_generator.rb` (GREEN)**

Overwrite `lib/apple_sdk_mac/glue_compiler/template_generator.rb` with:

```ruby
# frozen_string_literal: true
require "json"

module AppleSDKMac
  class GlueCompiler
    class TemplateGenerator
      HEADER = <<~SWIFT.freeze
        // CRuby symbols resolved at dlopen via -undefined dynamic_lookup
        @_silgen_name("rb_string_value_cstr")
        func rb_string_value_cstr(_ value: UnsafeMutablePointer<UInt>) -> UnsafePointer<CChar>
        @_silgen_name("rb_str_new_cstr")
        func rb_str_new_cstr(_ s: UnsafePointer<CChar>) -> UInt
        @_silgen_name("rb_num2ll")
        func rb_num2ll(_ v: UInt) -> Int64
        @_silgen_name("rb_num2ull")
        func rb_num2ull(_ v: UInt) -> UInt64
        @_silgen_name("rb_ll2inum")
        func rb_ll2inum(_ v: Int64) -> UInt
        @_silgen_name("rb_ull2inum")
        func rb_ull2inum(_ v: UInt64) -> UInt
        @_silgen_name("rb_num2dbl")
        func rb_num2dbl(_ v: UInt) -> Double
        @_silgen_name("rb_float_new")
        func rb_float_new(_ d: Double) -> UInt
        @_silgen_name("rb_raise")
        func rb_raise(_ klass: UInt, _ fmt: UnsafePointer<CChar>) -> Never
        @_silgen_name("rb_eRuntimeError")
        var rb_eRuntimeError: UInt

        let Qfalse: UInt = 0
        let Qnil:   UInt = 8
        let Qtrue:  UInt = 20
      SWIFT

      def generate(framework:, symbol:, glue_id:)
        return nil unless symbol[:kind] == "function" && symbol[:abi] == "c"
        params = parse_params(symbol[:parameters_json])
        return nil if params.any? { |p| p[:kind] == "unsupported" }

        in_params  = params.reject { |p| p[:is_out_param] }
        out_params = params.select { |p| p[:is_out_param] }
        return nil if out_params.length > 1

        out = out_params.first
        in_loads = in_params.each_with_index.map { |p, i| load_in_param(p, i) }
        call_args = params.map { |p| p[:is_out_param] ? "&outRef" : p[:name] }.join(", ")

        body = []
        body.concat(in_loads)
        if out
          body << "var outRef: #{strip_pointer(out[:type])} = #{strip_pointer(out[:type])}()"
          body << "let status = #{symbol[:name]}(#{call_args})"
          body << %(if status != 0 { rb_raise(rb_eRuntimeError, "OSStatus") })
          body << "return #{to_ruby_expr(out, "outRef")}"
        else
          ret_kind = return_kind(symbol[:signature])
          body << "let result = #{symbol[:name]}(#{call_args})"
          if ret_kind == "status_int"
            body << %(if result != 0 { rb_raise(rb_eRuntimeError, "OSStatus") })
            body << "return Qnil"
          elsif ret_kind == "void"
            body << "return Qnil"
          else
            body << "return #{to_ruby_expr_by_kind(ret_kind, symbol[:signature], "result")}"
          end
        end

        <<~SWIFT
          import #{framework}
          import Foundation

          #{HEADER}
          @c
          public func glue_#{glue_id}_#{symbol[:name]}(
              _ argv: UnsafePointer<UInt>, _ argc: Int32
          ) -> UInt {
              #{body.join("\n    ")}
          }
        SWIFT
      end

      private

      def parse_params(json)
        return [] if json.nil? || json.empty?
        JSON.parse(json, symbolize_names: true)
      end

      def load_in_param(p, i)
        name = p[:name]
        case p[:kind]
        when "string"
          cast = p[:type].include?("CFString") ? " as CFString" :
                 p[:type].include?("NSString") ? " as NSString" : ""
          "var v#{i} = argv[#{i}]; let #{name} = String(cString: rb_string_value_cstr(&v#{i}))#{cast}"
        when "int"
          "let #{name}: Int64 = rb_num2ll(argv[#{i}])"
        when "bool"
          "let #{name}: Bool = (argv[#{i}] != Qfalse && argv[#{i}] != Qnil)"
        when "float"
          "let #{name}: Double = rb_num2dbl(argv[#{i}])"
        when "opaque_ref"
          ref_type = strip_pointer(p[:type])
          unsigned?(p[:type]) ?
            "let #{name} = #{ref_type}(rb_num2ull(argv[#{i}]))" :
            "let #{name} = #{ref_type}(rb_num2ll(argv[#{i}]))"
        end
      end

      def to_ruby_expr(p, swift_var)
        case p[:kind]
        when "string"     then "rb_str_new_cstr(#{swift_var})"
        when "int"        then "rb_ll2inum(Int64(#{swift_var}))"
        when "bool"       then "(#{swift_var} ? Qtrue : Qfalse)"
        when "float"      then "rb_float_new(#{swift_var})"
        when "opaque_ref"
          unsigned?(p[:type]) ?
            "rb_ull2inum(UInt64(#{swift_var}))" :
            "rb_ll2inum(Int64(#{swift_var}))"
        end
      end

      def return_kind(signature)
        sig = signature.to_s.strip
        return "void"   if sig =~ /\A(?:void)\b/
        return "string" if sig =~ /\A(?:CFStringRef|NSString\s*\*|char\s*\*|const\s+char\s*\*)/
        return "bool"   if sig =~ /\A(?:_Bool|Bool|BOOL)\b/
        return "float"  if sig =~ /\A(?:double|float|CGFloat)\b/
        if sig =~ /\A(?:OSStatus|kern_return_t|int|signed|unsigned|U?Int(?:8|16|32|64)?|SInt(?:8|16|32|64)?|long|short|uint(?:8|16|32|64)_t|int(?:8|16|32|64)_t)\b/
          return "status_int"
        end
        if sig =~ /\A(\w+Ref)\b/
          return "opaque_ref"
        end
        "unsupported"
      end

      def to_ruby_expr_by_kind(kind, signature, swift_var)
        case kind
        when "string"     then "rb_str_new_cstr(#{swift_var})"
        when "bool"       then "(#{swift_var} ? Qtrue : Qfalse)"
        when "float"      then "rb_float_new(#{swift_var})"
        when "opaque_ref"
          signature.match?(/\A(?:UInt|uint)/) ?
            "rb_ull2inum(UInt64(#{swift_var}))" :
            "rb_ll2inum(Int64(#{swift_var}))"
        else
          "rb_ll2inum(Int64(#{swift_var}))"
        end
      end

      def strip_pointer(t)
        t.sub(/\s*\*.*\z/, "").gsub(/\b_(Nonnull|Nullable)\b/, "").strip
      end

      def unsigned?(t)
        t.match?(/\b(UInt|UInt8|UInt16|UInt32|UInt64|uint(8|16|32|64)_t|unsigned)\b/)
      end
    end
  end
end
```

- [ ] **Step 4: Run, verify GREEN**

```bash
cd ~/dev/src/github.com/bash0C7/rb-apple-sdk-mac
bash -c '. ~/.swiftly/env.sh && bundle exec ruby -Ilib -Itest test/glue_compiler/template_generator_test.rb'
```
Expected: 0 failures, 0 errors.

- [ ] **Step 5: Run full gem C suite to surface regressions**

Delegate to a subagent (per memory rule "Delegate rake test to subagent") and ensure pass/fail. Re-run targeted tests directly only if a failure surfaces.

- [ ] **Step 6: Commit**

```bash
git add lib/apple_sdk_mac/glue_compiler/template_generator.rb test/glue_compiler/template_generator_test.rb
git commit -m "feat: rewrite template_generator with kind-driven dispatch and @_silgen_name"
```

---

## Task 8: gem C — Delete ErrorBridge.swift

**Files:**
- Delete: `~/dev/src/github.com/bash0C7/rb-apple-sdk-mac/ext/apple_sdk_mac_runtime/Sources/AppleSDKMacRuntime/ErrorBridge.swift`

- [ ] **Step 1: Verify no remaining references**

```bash
cd ~/dev/src/github.com/bash0C7/rb-apple-sdk-mac
grep -rn "ErrorBridge" --include="*.swift" --include="*.rb" --include="*.c" --include="*.h" 2>&1
```
Expected: 0 references in production code (all template_generator references are now removed).

- [ ] **Step 2: Delete the file**

```bash
rm ext/apple_sdk_mac_runtime/Sources/AppleSDKMacRuntime/ErrorBridge.swift
```

- [ ] **Step 3: Rebuild the runtime to ensure no compile breakage**

```bash
cd ~/dev/src/github.com/bash0C7/rb-apple-sdk-mac
bash -c '. ~/.swiftly/env.sh && bundle exec rake compile' 2>&1 | tail -20
```
Expected: build succeeds.

- [ ] **Step 4: Commit**

```bash
git add -u
git commit -m "chore: drop ErrorBridge.swift; raise via @_silgen_name rb_raise from glue"
```

---

## Task 9: In-place reclassify + SQL verification

> **Replaces the original "4hr rebuild" approach.** The new fields (`kind`, `is_out_param`, `nullability`) are pure functions of `parameters_json` already in the DB — recompute in place via the dedicated rake task instead of re-fetching the SDK headers.
>
> Implementation plan: `~/dev/src/github.com/bash0C7/rb-apple-sdk-knowledge/docs/superpowers/plans/2026-05-05-reclassify-task.md` (Tasks 1–5 build the rake task + Kind module + tests; Task 6 is the docs pointer this task points back to; the steps below complete T9 of Bug C).

**Files:**
- Read-then-mutate: `~/dev/src/github.com/bash0C7/rb-apple-sdk-knowledge/data/sdk_knowledge_26.2.sqlite`
- Backup written by the task: `~/dev/src/github.com/bash0C7/rb-apple-sdk-knowledge/data/sdk_knowledge_26.2.sqlite.bak`
- Logs: `~/dev/src/github.com/bash0C7/rb-apple-sdk-knowledge/tmp/longrun/bug-c-reclassify.log` and `...-unsupported.jsonl`

- [ ] **Step 1: Implement the reclassify plan**

Execute Tasks 1–5 of `~/dev/src/github.com/bash0C7/rb-apple-sdk-knowledge/docs/superpowers/plans/2026-05-05-reclassify-task.md`. That builds `Importer::Kind`, `Reclassifier`, the `unsupported.jsonl` + `_summary` shape, and the `apple:knowledge:reclassify` rake task. After Task 5 the smoke run on the existing DB will already have produced an updated `parameters_json` for every row — so for the typical Bug C flow this single execution is enough and the screen-pattern launch below is only required if the smoke run was aborted or the DB has grown so large that it exceeds 2 minutes.

- [ ] **Step 2: Pre-run safety check (only needed if Step 1 smoke was not run, or before a re-run).** Confirm no other writer is active and the DB exists.

```bash
ls -la ~/dev/src/github.com/bash0C7/rb-apple-sdk-knowledge/data/sdk_knowledge_26.2.sqlite*
pgrep -fl 'rake apple:knowledge'   # must be empty
```

- [ ] **Step 3: Launch reclassify under the long-batch screen pattern (only required for re-run or if Step 1 smoke could not complete inline).** Per `~/dev/src/CLAUDE.md` "ロングバッチ実行パターン":

```bash
cd ~/dev/src/github.com/bash0C7/rb-apple-sdk-knowledge
mkdir -p tmp/longrun
screen -dmS bug-c-reclassify bash -c '
  cd ~/dev/src/github.com/bash0C7/rb-apple-sdk-knowledge
  bundle exec rake apple:knowledge:reclassify > tmp/longrun/bug-c-reclassify.log 2>&1
  echo "DONE: exit=$?" >> tmp/longrun/bug-c-reclassify.log
'
```

End the Claude turn here.

- [ ] **Step 4: In a later turn, verify completion (only if Step 3 was used).**

```bash
grep "^DONE:" ~/dev/src/github.com/bash0C7/rb-apple-sdk-knowledge/tmp/longrun/bug-c-reclassify.log
```
Must show `DONE: exit=0`. If absent the job is still running (or has crashed); inspect the log.

- [ ] **Step 5: Read the unsupported summary; enter recovery loop only if needed.**

```bash
tail -1 ~/dev/src/github.com/bash0C7/rb-apple-sdk-knowledge/tmp/longrun/reclassify-unsupported.jsonl | jq ._summary
```
For Bug C smoke acceptance, the only required outcome is that `MIDIClientCreate`'s `name` and `outClient` parameters classify correctly (next step). `notifyProc` and `notifyRefCon` MAY remain `unsupported` — that is acceptable. If extending `Kind.classify_kind` to absorb a high-count cluster is desired, do it now and re-run from Step 3; otherwise proceed.

- [ ] **Step 6: SQL verification (the original Task 9 acceptance check).**

```bash
sqlite3 ~/dev/src/github.com/bash0C7/rb-apple-sdk-knowledge/data/sdk_knowledge_26.2.sqlite \
  "SELECT s.parameters_json FROM symbols s JOIN frameworks f ON s.framework_id=f.id WHERE s.name='MIDIClientCreate' AND f.name='CoreMIDI';"
```
Expected: the JSON contains `"kind":"string"` for `name`, `"kind":"opaque_ref"` for `outClient`, and `"is_out_param":true` for `outClient`. (`notifyProc` / `notifyRefCon` may be `unsupported`.)

---

## Task 10: E2E verification

- [ ] **Step 1: Clear gem C cache to force fresh glue compilation**

```bash
rm -rf ~/.cache/rb-apple-sdk-mac/26.2
```

- [ ] **Step 2: Run gem C test suite via subagent**

Delegate to a general-purpose subagent: run `bash -c '. ~/.swiftly/env.sh && bundle exec rake test'` in `~/dev/src/github.com/bash0C7/rb-apple-sdk-mac`, report pass/fail counts and the outcome of `test_create_client_and_dispose`.

- [ ] **Step 3: Acceptance criterion**

`test_create_client_and_dispose` outcome must be **pass** (not omit, not fail). Total: ≥ 50 tests, 0 failures, 0 errors. Other tests that are gated on env vars (e.g. `test_live_ollama_returns_some_swift`) are allowed to remain omit.

If `test_create_client_and_dispose` does not pass, inspect the cached generated glue at `~/.cache/rb-apple-sdk-mac/26.2/sources/<glue_id>.swift` and the `glue.sqlite` `attempts` table to see the swiftc error. Address by patching `template_generator.rb` (likely a kind-specific edge case in the Apple-SDK signature) and re-run from Step 1.

- [ ] **Step 4: Commit any follow-up template_generator fixes (if needed)**

If smoke required template tweaks beyond what the unit tests caught, commit them with a clear `fix: ...` message and re-run Step 2.

- [ ] **Step 5: Final summary**

Push all commits across both gems. Update `MEMORY.md` with the resolution of Bug C.
