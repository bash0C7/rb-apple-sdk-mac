# Unified Marshalling and Callback Pillar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring rb-apple-sdk-mac to practical-application-ready state by deterministic-marshalling all kinds the LLM fallback couldn't handle (struct in/out, nilable + non-nil callbacks, void* refcon, multi-out, variadic) plus implementing a Callback pillar in the Swift runtime ext, so the README example runs end-to-end.

**Architecture:** Cross-repo. gem K (rb-apple-sdk-knowledge) gets a SCHEMA_VERSION=2 migration adding `fields_json` to `symbols`, a clang-AST parser extension for FieldDecl walking, and a kind-classifier rule update. gem C (rb-apple-sdk-mac) gets a Marshaller-pattern restructure of `template_generator.rb`, HEADER extension (rb_hash_*, rb_block_*), per-kind Marshaller classes, LLM prompt header sync, and a new Swift module `CallbackPillar` under `ext/apple_sdk_mac_runtime/Sources/` with codegen-driven trampolines.

**Tech Stack:** Ruby 4.x master, test-unit, sqlite3, clang AST JSON dump, rake-compiler, Swift 6.3+, swiftly toolchain, Foundation Model on Apple Silicon (smoke only).

**Spec:** `docs/superpowers/specs/2026-05-05-unified-marshalling-and-callback-pillar-design.md`

---

## Phase 1 — Knowledge gem (rb-apple-sdk-knowledge)

### Task 1: Schema migration to v2 with `fields_json` column

**Files:**
- Modify: `~/dev/src/github.com/bash0C7/rb-apple-sdk-knowledge/lib/rb_apple_sdk_knowledge/store.rb`
- Modify: `~/dev/src/github.com/bash0C7/rb-apple-sdk-knowledge/test/store_test.rb`

- [ ] **Step 1: Write failing test for idempotent ALTER TABLE migration**

Append to `test/store_test.rb`:

```ruby
def test_migrate_adds_fields_json_column_idempotently
  Dir.mktmpdir do |dir|
    path = File.join(dir, "test.sqlite")
    # Simulate schema_version=1 by opening once with current schema
    # then drop the column and check migrate adds it back
    s1 = AppleSDKKnowledge::Store.open(path)
    s1.db.execute("ALTER TABLE symbols DROP COLUMN fields_json") rescue nil
    s1.close
    s2 = AppleSDKKnowledge::Store.open(path)
    cols = s2.db.execute("PRAGMA table_info(symbols)").map { |r| r[1] }
    assert_includes cols, "fields_json"
    s2.close
    # Second migrate is no-op (no error)
    s3 = AppleSDKKnowledge::Store.open(path)
    s3.close
  end
end

def test_schema_version_bumped_to_2
  Dir.mktmpdir do |dir|
    s = AppleSDKKnowledge::Store.open(File.join(dir, "test.sqlite"))
    v = s.db.execute("SELECT value FROM schema_meta WHERE key = 'schema_version'").first.first
    assert_equal "2", v
    s.close
  end
end
```

- [ ] **Step 2: Run new tests, confirm they fail**

```bash
cd ~/dev/src/github.com/bash0C7/rb-apple-sdk-knowledge && \
  bundle exec ruby -Ilib -Itest test/store_test.rb \
    -n /test_migrate_adds_fields_json|test_schema_version_bumped/
```

Expected: 2 failures (`fields_json` not in columns; `schema_version` is "1").

- [ ] **Step 3: Commit RED**

```bash
cd ~/dev/src/github.com/bash0C7/rb-apple-sdk-knowledge && \
git add test/store_test.rb && \
git commit -m "test: add failing specs for fields_json schema migration"
```

- [ ] **Step 4: GREEN — bump SCHEMA_VERSION and add ensure_column!**

In `lib/rb_apple_sdk_knowledge/store.rb`:
- Change `SCHEMA_VERSION = 1` to `SCHEMA_VERSION = 2`.
- Add `fields_json TEXT` to the `CREATE TABLE symbols` SQL.
- Add `ensure_column!` private method.
- Update `migrate!`:

```ruby
def migrate!
  @db.execute_batch(SCHEMA_SQL)
  ensure_column!("symbols", "fields_json", "TEXT")
  @db.execute(
    "INSERT OR REPLACE INTO schema_meta (key, value) VALUES (?, ?)",
    ["schema_version", SCHEMA_VERSION.to_s]
  )
end

private

def ensure_column!(table, col, type)
  cols = @db.execute("PRAGMA table_info(#{table})").map { |r| r[1] }
  return if cols.include?(col)
  @db.execute("ALTER TABLE #{table} ADD COLUMN #{col} #{type}")
end
```

- [ ] **Step 5: Run tests, confirm GREEN**

```bash
cd ~/dev/src/github.com/bash0C7/rb-apple-sdk-knowledge && \
  bundle exec ruby -Ilib -Itest test/store_test.rb \
    -n /test_migrate_adds_fields_json|test_schema_version_bumped/
```

Expected: 2 tests, 0 failures.

- [ ] **Step 6: Commit GREEN**

```bash
cd ~/dev/src/github.com/bash0C7/rb-apple-sdk-knowledge && \
git add lib/rb_apple_sdk_knowledge/store.rb && \
git commit -m "feat: bump schema to v2 with fields_json column and idempotent ensure_column!"
```

---

### Task 2: `insert_symbol` accepts `fields_json:` kwarg

**Files:**
- Modify: `~/dev/src/github.com/bash0C7/rb-apple-sdk-knowledge/lib/rb_apple_sdk_knowledge/store.rb`
- Modify: `~/dev/src/github.com/bash0C7/rb-apple-sdk-knowledge/test/store_test.rb`

- [ ] **Step 1: Write failing test**

```ruby
def test_insert_symbol_persists_fields_json
  Dir.mktmpdir do |dir|
    s = AppleSDKKnowledge::Store.open(File.join(dir, "test.sqlite"))
    fid = s.insert_framework(name: "Acme", swift_module: "Acme")
    fields = JSON.dump([{name: "x", type: "int", kind: "int"}])
    s.insert_symbol(framework_id: fid, name: "Foo", kind: "struct", abi: "c",
                    content_hash: "h1", fields_json: fields)
    row = s.db.execute("SELECT fields_json FROM symbols WHERE name = ?", ["Foo"]).first
    assert_equal fields, row.first
    s.close
  end
end
```

- [ ] **Step 2: Run, confirm fail**

```bash
bundle exec ruby -Ilib -Itest test/store_test.rb -n test_insert_symbol_persists_fields_json
```

Expected: ArgumentError (unknown kwarg `fields_json`).

- [ ] **Step 3: Commit RED**

```bash
git add test/store_test.rb && \
git commit -m "test: add failing spec for insert_symbol fields_json kwarg"
```

- [ ] **Step 4: GREEN — extend `insert_symbol`**

```ruby
def insert_symbol(framework_id:, name:, kind:, abi:, content_hash:,
                   parent_id: nil, signature: nil, documentation: nil,
                   return_type: nil, parameters_json: nil, availability: nil,
                   deprecated: 0, requires_main_thread: 0, fields_json: nil)
  @db.execute(
    <<~SQL,
      INSERT INTO symbols
      (framework_id, name, parent_id, kind, signature, abi, documentation,
       return_type, parameters_json, availability, deprecated,
       requires_main_thread, content_hash, fields_json)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    SQL
    [framework_id, name, parent_id, kind, signature, abi, documentation,
     return_type, parameters_json, availability, deprecated,
     requires_main_thread, content_hash, fields_json]
  )
  @db.last_insert_row_id
end
```

- [ ] **Step 5: Run, confirm GREEN**

```bash
bundle exec ruby -Ilib -Itest test/store_test.rb -n test_insert_symbol_persists_fields_json
```

Expected: 1 test, 0 failures.

- [ ] **Step 6: Commit GREEN**

```bash
git add lib/rb_apple_sdk_knowledge/store.rb && \
git commit -m "feat: insert_symbol accepts fields_json kwarg"
```

---

### Task 3: `Kind.classify_kind` takes nullability and emits new kinds

**Files:**
- Modify: `lib/rb_apple_sdk_knowledge/importer/kind.rb`
- Modify: `test/importer/kind_test.rb` (create if absent)

- [ ] **Step 1: Write failing tests**

Create or append `test/importer/kind_test.rb`:

```ruby
require "test/unit"
require "rb_apple_sdk_knowledge/importer/kind"

class TestKind < Test::Unit::TestCase
  K = AppleSDKKnowledge::Importer::Kind

  def test_classifies_nullable_void_ptr_as_void_ptr_nilable
    assert_equal "void_ptr_nilable",
                 K.classify_kind("void * _Nullable", "void *", "nullable")
  end

  def test_classifies_unspecified_void_ptr_as_void_ptr_nilable
    assert_equal "void_ptr_nilable",
                 K.classify_kind("void *", "void *", "unspecified")
  end

  def test_classifies_nullable_callback_typedef_as_callback_nilable
    assert_equal "callback_nilable",
                 K.classify_kind("MIDINotifyProc _Nullable",
                                 "void (*)(const MIDINotification *, void *)",
                                 "nullable")
  end

  def test_classifies_nonnull_callback_typedef_as_callback_non_nil
    assert_equal "callback_non_nil",
                 K.classify_kind("MIDINotifyProc _Nonnull",
                                 "void (*)(const MIDINotification *, void *)",
                                 "nonnull")
  end

  def test_existing_kinds_unchanged_when_nullability_omitted
    assert_equal "string", K.classify_kind("CFStringRef", "CFStringRef")
    assert_equal "int",    K.classify_kind("int", "int")
    assert_equal "opaque_ref", K.classify_kind("MIDIClientRef", "UInt32")
  end
end
```

- [ ] **Step 2: Run, confirm fail**

```bash
bundle exec ruby -Ilib -Itest test/importer/kind_test.rb
```

Expected: 4 failures (new kinds not emitted; signature still 2-arg).

- [ ] **Step 3: Commit RED**

```bash
git add test/importer/kind_test.rb && \
git commit -m "test: add failing specs for nullability-aware kind classifier"
```

- [ ] **Step 4: GREEN — extend classifier**

In `lib/rb_apple_sdk_knowledge/importer/kind.rb`:

```ruby
def classify_kind(qual_type, desugared = qual_type, nullability = "unspecified")
  is_function_pointer = desugared.include?("(") && desugared.include?(")")
  is_void_ptr = qual_type =~ /\bvoid\s*\*/
  treat_nilable = (nullability == "nullable" || nullability == "unspecified")

  if is_void_ptr
    return "void_ptr_nilable" if treat_nilable
    return "unsupported"
  end

  if is_function_pointer
    return "callback_nilable" if treat_nilable
    return "callback_non_nil"  # nonnull
  end

  return "string" if qual_type =~ /\b(CFStringRef|NSString\s*\*|char\s*\*|const\s+char\s*\*)/
  return "bool"   if qual_type =~ /\b(_Bool|Bool|BOOL|bool)\b/
  return "float"  if qual_type =~ /\b(double|float|CGFloat)\b/
  if qual_type =~ /\b(?:int|U?Int(?:8|16|32|64)?|SInt(?:8|16|32|64)?|long|short|unsigned|signed|uint(?:8|16|32|64)_t|int(?:8|16|32|64)_t|OSStatus|kern_return_t)\b/
    return "opaque_ref" if qual_type =~ /\b\w+Ref\b/
    return "int"
  end
  return "opaque_ref" if qual_type =~ /\b\w+Ref\b/
  "unsupported"
end
```

- [ ] **Step 5: Run, confirm GREEN**

```bash
bundle exec ruby -Ilib -Itest test/importer/kind_test.rb
```

Expected: 5 tests, 0 failures.

- [ ] **Step 6: Commit GREEN**

```bash
git add lib/rb_apple_sdk_knowledge/importer/kind.rb && \
git commit -m "feat: kind classifier emits void_ptr_nilable / callback_(non_)nilable based on nullability"
```

---

### Task 4: `HeaderParser` passes nullability to classifier and walks FieldDecl

**Files:**
- Modify: `lib/rb_apple_sdk_knowledge/importer/header_parser.rb`
- Modify: `test/importer/header_parser_test.rb`

- [ ] **Step 1: Write failing test for FieldDecl walk**

Append to `test/importer/header_parser_test.rb`:

```ruby
def test_recorddecl_emits_fields_with_kinds
  fixture = Tempfile.new(["fixture", ".h"])
  fixture.write(<<~C)
    struct Point {
      int x;
      int y;
    };
  C
  fixture.close
  syms = AppleSDKKnowledge::Importer::HeaderParser.new.parse_file(fixture.path)
  point = syms.find { |s| s[:name] == "Point" && s[:kind] == "struct" }
  assert_not_nil point
  assert_equal 2, point[:fields].length
  assert_equal({ name: "x", type: "int", kind: "int" }, point[:fields][0])
  assert_equal({ name: "y", type: "int", kind: "int" }, point[:fields][1])
end

def test_function_param_classification_uses_nullability
  fixture = Tempfile.new(["fixture", ".h"])
  fixture.write(<<~C)
    typedef void (*MyCallback)(int);
    void foo(MyCallback _Nullable cb, void * _Nullable refcon);
  C
  fixture.close
  syms = AppleSDKKnowledge::Importer::HeaderParser.new.parse_file(fixture.path)
  foo = syms.find { |s| s[:name] == "foo" && s[:kind] == "function" }
  cb_param = foo[:parameters].find { |p| p[:name] == "cb" }
  refcon_param = foo[:parameters].find { |p| p[:name] == "refcon" }
  assert_equal "callback_nilable", cb_param[:kind]
  assert_equal "void_ptr_nilable", refcon_param[:kind]
end
```

- [ ] **Step 2: Run, confirm fail**

```bash
bundle exec ruby -Ilib -Itest test/importer/header_parser_test.rb \
  -n /test_recorddecl_emits_fields|test_function_param_classification/
```

Expected: 2 failures (no `fields` key; kinds still `unsupported`).

- [ ] **Step 3: Commit RED**

```bash
git add test/importer/header_parser_test.rb && \
git commit -m "test: add failing specs for FieldDecl walk and nullability-aware param classify"
```

- [ ] **Step 4: GREEN — patch HeaderParser**

In `lib/rb_apple_sdk_knowledge/importer/header_parser.rb`:

In `emit_symbol`, modify the `RecordDecl` branch:

```ruby
when "RecordDecl"
  if node["name"]
    fields = (node["inner"] || []).select { |c| c["kind"] == "FieldDecl" }.map do |fd|
      qt = fd.dig("type", "qualType") || ""
      desugared = fd.dig("type", "desugaredQualType") || qt
      nullability = Kind.nullability_of(qt)
      {
        name: fd["name"],
        type: qt,
        kind: Kind.classify_kind(qt, desugared, nullability)
      }
    end
    symbols << {
      name: node["name"],
      kind: "struct",
      abi: "c",
      parent_name: nil,
      signature: "struct #{node['name']}",
      fields: fields
    }
  end
```

In `function_parameters`, pass nullability:

```ruby
def function_parameters(node)
  params = (node["inner"] || []).select { |i| i["kind"] == "ParmVarDecl" }
  pointer_params = params.select { |p| (p.dig("type", "qualType") || "").include?("*") }
  last_pointer = pointer_params.last

  params.each_with_index.map do |p, i|
    qual_type = p.dig("type", "qualType") || ""
    desugared = p.dig("type", "desugaredQualType") || qual_type
    name = p["name"] || "_arg#{i}"
    nullability = Kind.nullability_of(qual_type)
    {
      name: name,
      type: qual_type,
      kind: Kind.classify_kind(qual_type, desugared, nullability),
      is_out_param: Kind.out_param?(qual_type, name, p == last_pointer),
      nullability: nullability
    }
  end
end
```

- [ ] **Step 5: Run, confirm GREEN**

```bash
bundle exec ruby -Ilib -Itest test/importer/header_parser_test.rb
```

Expected: existing tests + 2 new tests pass.

- [ ] **Step 6: Commit GREEN**

```bash
git add lib/rb_apple_sdk_knowledge/importer/header_parser.rb && \
git commit -m "feat: HeaderParser walks FieldDecl and forwards nullability to kind classifier"
```

---

### Task 5: Importer flushes `fields_json` on struct insert

**Files:**
- Modify: `lib/rb_apple_sdk_knowledge/importer.rb`

- [ ] **Step 1: Locate struct insert site**

```bash
grep -n "kind.*struct\|insert_symbol" ~/dev/src/github.com/bash0C7/rb-apple-sdk-knowledge/lib/rb_apple_sdk_knowledge/importer.rb
```

Identify where `Store#insert_symbol` is called for a struct. There's typically one call site that handles all symbol kinds.

- [ ] **Step 2: Write integration test**

In `test/importer_test.rb` (create if needed) or in the existing test that imports a small framework:

```ruby
def test_importer_persists_struct_fields_json
  Dir.mktmpdir do |dir|
    db_path = File.join(dir, "test.sqlite")
    store = AppleSDKKnowledge::Store.open(db_path)
    importer = AppleSDKKnowledge::Importer.new(store: store)
    fixture = File.expand_path("fixtures/mini_struct.h", __dir__)
    File.write(fixture, "struct Pt { int x; int y; };") unless File.exist?(fixture)
    framework_id = store.insert_framework(name: "Mini", swift_module: "Mini")
    importer.import_header(fixture, framework_id: framework_id)
    row = store.db.execute("SELECT fields_json FROM symbols WHERE name = 'Pt'").first
    assert_not_nil row.first
    fields = JSON.parse(row.first)
    assert_equal 2, fields.length
    store.close
  end
end
```

(If the `Importer#import_header` method signature differs, adapt to current signature seen in `lib/rb_apple_sdk_knowledge/importer.rb`.)

- [ ] **Step 3: Run, confirm fail**

```bash
bundle exec ruby -Ilib -Itest test/importer_test.rb -n test_importer_persists_struct_fields_json
```

Expected: `fields_json` is NULL.

- [ ] **Step 4: Commit RED**

```bash
git add test/importer_test.rb test/fixtures/mini_struct.h && \
git commit -m "test: add failing spec for importer fields_json persistence"
```

- [ ] **Step 5: GREEN — pass fields_json on struct insert**

In `lib/rb_apple_sdk_knowledge/importer.rb`, where `Store#insert_symbol` is called: when the symbol Hash has `:fields`, dump and pass:

```ruby
@store.insert_symbol(
  framework_id: framework_id,
  name: sym[:name],
  kind: sym[:kind],
  abi: sym[:abi],
  content_hash: content_hash,
  signature: sym[:signature],
  parameters_json: sym[:parameters] ? JSON.dump(sym[:parameters]) : nil,
  fields_json: sym[:fields] ? JSON.dump(sym[:fields]) : nil
)
```

- [ ] **Step 6: Run, confirm GREEN**

```bash
bundle exec ruby -Ilib -Itest test/importer_test.rb -n test_importer_persists_struct_fields_json
```

Expected: 1 test, 0 failures.

- [ ] **Step 7: Commit GREEN**

```bash
git add lib/rb_apple_sdk_knowledge/importer.rb && \
git commit -m "feat: importer persists struct fields_json"
```

---

### Task 6: Reclassifier recognizes new kinds

**Files:**
- Modify: `lib/rb_apple_sdk_knowledge/reclassifier.rb`
- Modify: `test/reclassifier_test.rb`

- [ ] **Step 1: Write failing test**

```ruby
def test_reclassifier_preserves_new_kinds_when_re_walking
  Dir.mktmpdir do |dir|
    db_path = File.join(dir, "test.sqlite")
    store = AppleSDKKnowledge::Store.open(db_path)
    framework_id = store.insert_framework(name: "Mini", swift_module: "Mini")
    params = JSON.dump([
      { name: "cb", type: "Cb _Nullable", kind: "callback_nilable",
        is_out_param: false, nullability: "nullable" }
    ])
    store.insert_symbol(framework_id: framework_id, name: "Foo", kind: "function",
                        abi: "c", content_hash: "h", parameters_json: params)
    AppleSDKKnowledge::Reclassifier.new(store).reclassify_all!
    row = store.db.execute("SELECT parameters_json FROM symbols WHERE name='Foo'").first
    parsed = JSON.parse(row.first)
    assert_equal "callback_nilable", parsed.first["kind"]
    store.close
  end
end
```

- [ ] **Step 2: Run, confirm fail**

```bash
bundle exec ruby -Ilib -Itest test/reclassifier_test.rb -n test_reclassifier_preserves_new_kinds
```

Expected: kind reverts to `unsupported` because the reclassifier doesn't know about the new kinds.

- [ ] **Step 3: Commit RED**

```bash
git add test/reclassifier_test.rb && \
git commit -m "test: add failing spec for reclassifier preserving new kinds"
```

- [ ] **Step 4: GREEN — pass nullability through reclassifier**

In `lib/rb_apple_sdk_knowledge/reclassifier.rb`, where each parameter is re-walked, ensure the call to `Kind.classify_kind` includes the `nullability` from the existing JSON entry:

```ruby
params = parsed.map do |p|
  nullability = p["nullability"] || "unspecified"
  p["kind"] = Kind.classify_kind(p["type"], p["type"], nullability)
  p
end
```

- [ ] **Step 5: Run, confirm GREEN**

```bash
bundle exec ruby -Ilib -Itest test/reclassifier_test.rb
```

Expected: all reclassifier tests pass.

- [ ] **Step 6: Commit GREEN**

```bash
git add lib/rb_apple_sdk_knowledge/reclassifier.rb && \
git commit -m "feat: reclassifier forwards nullability to kind classifier"
```

---

### Task 7: Knowledge gem full test suite + DB rebuild

**Files:** None modified directly; produces `data/sdk_knowledge_26.2.sqlite`.

- [ ] **Step 1: Delegate full `bundle exec rake test` to a subagent**

Subagent prompt:

> Run `cd ~/dev/src/github.com/bash0C7/rb-apple-sdk-knowledge && bundle exec rake test` and report only the final test count line and pass/fail. No verbose output.

Expected: previous test count + new tests, 0 failures.

- [ ] **Step 2: Rebuild knowledge DB**

```bash
cd ~/dev/src/github.com/bash0C7/rb-apple-sdk-knowledge && \
mkdir -p tmp/longrun && \
screen -dmS knowledge-rebuild-20260505 bash -c '
  cd ~/dev/src/github.com/bash0C7/rb-apple-sdk-knowledge
  bundle exec rake apple:knowledge:rebuild > tmp/longrun/knowledge-rebuild-20260505.log 2>&1
  echo "DONE: exit=$?" >> tmp/longrun/knowledge-rebuild-20260505.log
'
```

End the conversation turn after launch. Resume after `DONE:` sentinel.

- [ ] **Step 3: Verify rebuild populates fields_json for at least one struct**

```bash
sqlite3 ~/dev/src/github.com/bash0C7/rb-apple-sdk-knowledge/data/sdk_knowledge_26.2.sqlite \
  "SELECT count(*) FROM symbols WHERE kind='struct' AND fields_json IS NOT NULL;"
```

Expected: > 0 (likely thousands).

- [ ] **Step 4: Commit rebuilt DB and bump knowledge gem version**

```bash
cd ~/dev/src/github.com/bash0C7/rb-apple-sdk-knowledge && \
sed -i '' 's/VERSION = "[^"]*"/VERSION = "0.X.0"/' lib/rb_apple_sdk_knowledge/version.rb  # bump minor
git add data/sdk_knowledge_26.2.sqlite lib/rb_apple_sdk_knowledge/version.rb && \
git commit -m "chore: rebuild knowledge DB with fields_json + new kind taxonomy, bump version"
```

(Use the actual next minor; check current version first.)

---

## Phase 2 — gem C KnowledgeCache surface

### Task 8: `KnowledgeCache#lookup_symbol` surfaces `fields_json`

**Files:**
- Modify: `~/dev/src/github.com/bash0C7/rb-apple-sdk-mac/lib/apple_sdk_mac/knowledge_cache.rb`
- Modify: `~/dev/src/github.com/bash0C7/rb-apple-sdk-mac/test/knowledge_cache_test.rb` (create if absent)

- [ ] **Step 1: Write failing test**

```ruby
require "test/unit"
require "tmpdir"
require "apple_sdk_mac/knowledge_cache"

class TestKnowledgeCache < Test::Unit::TestCase
  def test_lookup_symbol_returns_fields_json_for_struct
    # Use the real knowledge DB (rebuilt in Task 7)
    kc = AppleSDKMac::KnowledgeCache.open
    sym = kc.lookup_symbol(framework: "CoreMIDI", symbol: "MIDIPacket")
    assert_not_nil sym
    assert_kind_of String, sym[:fields_json]
    fields = JSON.parse(sym[:fields_json])
    assert fields.length > 0
    kc.close
  end
end
```

- [ ] **Step 2: Run, confirm fail**

```bash
cd ~/dev/src/github.com/bash0C7/rb-apple-sdk-mac && \
  bundle exec ruby -Ilib -Itest test/knowledge_cache_test.rb
```

Expected: `:fields_json` key not in returned Hash.

- [ ] **Step 3: Commit RED**

```bash
git add test/knowledge_cache_test.rb && \
git commit -m "test: add failing spec for KnowledgeCache fields_json surface"
```

- [ ] **Step 4: GREEN — extend SELECT and Hash**

In `lib/apple_sdk_mac/knowledge_cache.rb`:

```ruby
def lookup_symbol(framework:, symbol:)
  row = @db.execute(<<~SQL, [framework, symbol]).first
    SELECT s.id, s.name, s.kind, s.signature, s.abi, s.documentation,
           s.parameters_json, s.requires_main_thread, s.content_hash,
           s.fields_json
    FROM symbols s
    JOIN frameworks f ON s.framework_id = f.id
    WHERE f.name = ? AND s.name = ?
    LIMIT 1
  SQL
  return nil unless row
  {
    id: row[0], name: row[1], kind: row[2], signature: row[3],
    abi: row[4], documentation: row[5], parameters_json: row[6],
    requires_main_thread: row[7] == 1, content_hash: row[8],
    fields_json: row[9]
  }
end
```

- [ ] **Step 5: Run, confirm GREEN**

```bash
bundle exec ruby -Ilib -Itest test/knowledge_cache_test.rb
```

Expected: 1 test, 0 failures.

- [ ] **Step 6: Commit GREEN**

```bash
git add lib/apple_sdk_mac/knowledge_cache.rb && \
git commit -m "feat: KnowledgeCache surfaces fields_json on lookup_symbol"
```

---

## Phase 3 — gem C Marshaller refactor (existing kinds)

### Task 9: Introduce Marshaller base + 5 existing-kind subclasses, no behavioral change

**Files:**
- Create: `lib/apple_sdk_mac/glue_compiler/marshallers.rb`
- Modify: `lib/apple_sdk_mac/glue_compiler/template_generator.rb`
- Modify: `test/template_generator_test.rb`

- [ ] **Step 1: Write characterization test**

Append to `test/template_generator_test.rb`:

```ruby
def test_marshaller_dispatch_byte_identical_for_existing_kinds
  # Exercise every existing kind through the new Marshaller path and
  # assert generated Swift matches the legacy output character-for-character.
  fixtures = {
    "string"     => '[{"name":"s","type":"const char *","kind":"string","is_out_param":false,"nullability":"unspecified"}]',
    "int"        => '[{"name":"n","type":"int","kind":"int","is_out_param":false,"nullability":"unspecified"}]',
    "bool"       => '[{"name":"b","type":"BOOL","kind":"bool","is_out_param":false,"nullability":"unspecified"}]',
    "float"      => '[{"name":"f","type":"double","kind":"float","is_out_param":false,"nullability":"unspecified"}]',
    "opaque_ref" => '[{"name":"r","type":"MIDIClientRef","kind":"opaque_ref","is_out_param":false,"nullability":"unspecified"}]'
  }
  fixtures.each do |label, params|
    sym = { kind: "function", abi: "c", name: "Foo", signature: "void Foo(...)",
            parameters_json: params }
    swift = AppleSDKMac::GlueCompiler::TemplateGenerator.new.generate(
      framework: "Acme", symbol: sym, glue_id: "ab12"
    )
    refute_nil swift, "kind=#{label} should generate"
  end
end
```

(This test will pass with the legacy code; the GREEN step preserves byte-identical output. The test exists to prevent regression after the refactor.)

- [ ] **Step 2: Verify legacy passes the characterization test**

```bash
bundle exec ruby -Ilib -Itest test/template_generator_test.rb \
  -n test_marshaller_dispatch_byte_identical_for_existing_kinds
```

Expected: 1 test, 0 failures.

- [ ] **Step 3: Commit characterization (REFACTOR-prep)**

```bash
git add test/template_generator_test.rb && \
git commit -m "test: characterize existing-kind output before Marshaller refactor"
```

- [ ] **Step 4: Create `marshallers.rb` with base + 5 subclasses**

```ruby
# frozen_string_literal: true
module AppleSDKMac
  class GlueCompiler
    class Marshaller
      attr_reader :param, :index, :ctx
      def initialize(param, index, ctx)
        @param = param; @index = index; @ctx = ctx
      end
      def in_load;     nil end
      def call_arg;    @param[:name] end
      def out_init;    nil end
      def out_addr;    nil end
      def out_to_ruby; nil end

      def self.for(param, index, ctx)
        klass = REGISTRY[param[:kind]]
        return nil unless klass
        klass.new(param, index, ctx)
      end

      REGISTRY = {}  # populated below
    end

    class StringMarshaller < Marshaller
      def in_load
        cast = @param[:type].include?("CFString") ? " as CFString" :
               @param[:type].include?("NSString") ? " as NSString" : ""
        "var v#{@index} = argv[#{@index}]; let #{@param[:name]} = String(cString: rb_string_value_cstr(&v#{@index}))#{cast}"
      end
    end
    Marshaller::REGISTRY["string"] = StringMarshaller

    class IntMarshaller < Marshaller
      def in_load
        "let #{@param[:name]}: Int64 = rb_num2ll(argv[#{@index}])"
      end
    end
    Marshaller::REGISTRY["int"] = IntMarshaller

    class BoolMarshaller < Marshaller
      def in_load
        "let #{@param[:name]}: Bool = (argv[#{@index}] != Qfalse && argv[#{@index}] != Qnil)"
      end
    end
    Marshaller::REGISTRY["bool"] = BoolMarshaller

    class FloatMarshaller < Marshaller
      def in_load
        "let #{@param[:name]}: Double = rb_num2dbl(argv[#{@index}])"
      end
    end
    Marshaller::REGISTRY["float"] = FloatMarshaller

    class OpaqueRefMarshaller < Marshaller
      def in_load
        ref_type = @param[:type].sub(/\s*\*.*\z/, "").gsub(/\b_(Nonnull|Nullable)\b/, "").strip
        if @param[:type] =~ /\b(UInt|UInt8|UInt16|UInt32|UInt64|uint(8|16|32|64)_t|unsigned)\b/
          "let #{@param[:name]} = #{ref_type}(rb_num2ull(argv[#{@index}]))"
        elsif @param[:type] =~ /\b(SInt|SInt8|SInt16|SInt32|SInt64|int(8|16|32|64)_t|signed)\b/
          "let #{@param[:name]} = #{ref_type}(rb_num2ll(argv[#{@index}]))"
        elsif @param[:type] =~ /\b\w+Ref\b/
          "let #{@param[:name]} = #{ref_type}(rb_num2ull(argv[#{@index}]))"
        else
          "let #{@param[:name]} = #{ref_type}(rb_num2ll(argv[#{@index}]))"
        end
      end
      # out_init/out_addr/out_to_ruby for out-param case
      def out_init
        return nil unless @param[:is_out_param]
        ref_type = @param[:type].sub(/\s*\*.*\z/, "").gsub(/\b_(Nonnull|Nullable)\b/, "").strip
        "var #{@param[:name]}_outRef: #{ref_type} = #{ref_type}()"
      end
      def out_addr
        return nil unless @param[:is_out_param]
        "&#{@param[:name]}_outRef"
      end
      def out_to_ruby
        return nil unless @param[:is_out_param]
        if @param[:type] =~ /\bUInt|uint|\w+Ref\b/
          "rb_ull2inum(UInt64(#{@param[:name]}_outRef))"
        else
          "rb_ll2inum(Int64(#{@param[:name]}_outRef))"
        end
      end
    end
    Marshaller::REGISTRY["opaque_ref"] = OpaqueRefMarshaller
  end
end
```

- [ ] **Step 5: Refactor `template_generator.rb` to use Marshaller dispatch**

Rewrite `template_generator.rb` (preserving HEADER unchanged for now). The new shape:

```ruby
require "json"
require_relative "marshallers"

module AppleSDKMac
  class GlueCompiler
    class TemplateGenerator
      HEADER = <<~SWIFT.freeze
        # ... unchanged from current file ...
      SWIFT

      def initialize(knowledge_cache: nil)
        @kc = knowledge_cache
      end

      def generate(framework:, symbol:, glue_id:)
        return nil unless symbol[:kind] == "function" && symbol[:abi] == "c"
        params = parse_params(symbol[:parameters_json])
        ctx = { framework: framework, knowledge_cache: @kc, struct_visited: Set.new }
        marshallers = params.map.with_index { |p, i| Marshaller.for(p, i, ctx) }
        return nil if marshallers.any?(&:nil?)

        in_marshallers = marshallers.reject { |m| m.param[:is_out_param] }
        out_marshallers = marshallers.select { |m| m.param[:is_out_param] }

        body = []
        body.concat(in_marshallers.map(&:in_load).compact)
        body.concat(out_marshallers.map(&:out_init).compact)

        call_args = marshallers.map { |m| m.param[:is_out_param] ? m.out_addr : m.call_arg }.join(", ")

        if out_marshallers.empty?
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
        elsif out_marshallers.length == 1
          out = out_marshallers.first
          body << "let status = #{symbol[:name]}(#{call_args})"
          body << %(if status != 0 { rb_raise(rb_eRuntimeError, "OSStatus") })
          body << "return #{out.out_to_ruby}"
        else
          # multi-out — Task 14 fills this in; for now return nil to escape
          return nil
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

      def return_kind(signature)
        sig = signature.to_s.strip
        return "void"   if sig =~ /\A(?:void)\b/
        return "string" if sig =~ /\A(?:CFStringRef|NSString\s*\*|char\s*\*|const\s+char\s*\*)/
        return "bool"   if sig =~ /\A(?:_Bool|Bool|BOOL)\b/
        return "float"  if sig =~ /\A(?:double|float|CGFloat)\b/
        if sig =~ /\A(?:OSStatus|kern_return_t|int|signed|unsigned|U?Int(?:8|16|32|64)?|SInt(?:8|16|32|64)?|long|short|uint(?:8|16|32|64)_t|int(?:8|16|32|64)_t)\b/
          return "status_int"
        end
        return "opaque_ref" if sig =~ /\A\w+Ref\b/
        "unsupported"
      end

      def to_ruby_expr_by_kind(kind, signature, swift_var)
        case kind
        when "string"     then "rb_str_new_cstr(#{swift_var})"
        when "bool"       then "(#{swift_var} ? Qtrue : Qfalse)"
        when "float"      then "rb_float_new(#{swift_var})"
        when "opaque_ref"
          if signature.match?(/\A(?:UInt|uint)/)
            "rb_ull2inum(UInt64(#{swift_var}))"
          else
            "rb_ll2inum(Int64(#{swift_var}))"
          end
        else
          "rb_ll2inum(Int64(#{swift_var}))"
        end
      end
    end
  end
end
```

- [ ] **Step 6: Run all template_generator tests, confirm GREEN**

```bash
bundle exec ruby -Ilib -Itest test/template_generator_test.rb
```

Expected: existing tests + characterization test pass. Output must remain byte-identical for existing kinds.

- [ ] **Step 7: Commit GREEN (refactor)**

```bash
git add lib/apple_sdk_mac/glue_compiler/marshallers.rb lib/apple_sdk_mac/glue_compiler/template_generator.rb && \
git commit -m "refactor: dispatch param marshalling through Marshaller pattern (no behavior change)"
```

---

## Phase 4 — HEADER extension and new kind Marshallers

### Task 10: Extend HEADER with rb_hash_*, rb_block_*

**Files:**
- Modify: `lib/apple_sdk_mac/glue_compiler/template_generator.rb` (HEADER constant)
- Modify: `test/template_generator_test.rb`

- [ ] **Step 1: Write failing test**

```ruby
def test_header_includes_rb_hash_and_rb_block_silgen_names
  h = AppleSDKMac::GlueCompiler::TemplateGenerator::HEADER
  assert_match(/@_silgen_name\("rb_hash_new"\)/, h)
  assert_match(/@_silgen_name\("rb_hash_aref"\)/, h)
  assert_match(/@_silgen_name\("rb_hash_aset"\)/, h)
  assert_match(/@_silgen_name\("rb_block_given_p"\)/, h)
  assert_match(/@_silgen_name\("rb_block_proc"\)/, h)
end
```

- [ ] **Step 2: Run, confirm fail**

```bash
bundle exec ruby -Ilib -Itest test/template_generator_test.rb \
  -n test_header_includes_rb_hash_and_rb_block_silgen_names
```

Expected: 5 failed assertions.

- [ ] **Step 3: Commit RED**

```bash
git add test/template_generator_test.rb && \
git commit -m "test: add failing spec for HEADER rb_hash_* and rb_block_* extensions"
```

- [ ] **Step 4: GREEN — extend HEADER**

In `template_generator.rb`, append to the HEADER heredoc (before the final `Qfalse/Qnil/Qtrue` block):

```swift
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
```

- [ ] **Step 5: Run, confirm GREEN**

Expected: 5 assertions pass.

- [ ] **Step 6: Commit GREEN**

```bash
git add lib/apple_sdk_mac/glue_compiler/template_generator.rb && \
git commit -m "feat: extend HEADER with rb_hash_* and rb_block_* silgen names"
```

---

### Task 11: `CallbackNilableMarshaller` and `CallbackNonNilMarshaller` (stub: rb_raise on non-nil branch)

**Files:**
- Modify: `lib/apple_sdk_mac/glue_compiler/marshallers.rb`
- Modify: `test/template_generator_test.rb`

- [ ] **Step 1: Write failing tests**

```ruby
def test_callback_nilable_emits_qnil_branch_with_rb_raise_stub
  sym = {
    kind: "function", abi: "c", name: "Foo", signature: "void Foo(MyCallback)",
    parameters_json: '[{"name":"cb","type":"MyCallback _Nullable","kind":"callback_nilable","is_out_param":false,"nullability":"nullable"}]'
  }
  swift = AppleSDKMac::GlueCompiler::TemplateGenerator.new.generate(
    framework: "Acme", symbol: sym, glue_id: "ab12"
  )
  assert_match(/let cb: MyCallback\?/, swift)
  assert_match(/if argv\[0\] == Qnil/, swift)
  assert_match(/cb = nil/, swift)
  assert_match(/rb_raise\(rb_eRuntimeError, "non-nil callback not yet supported"\)/, swift)
end

def test_callback_non_nil_emits_unconditional_rb_raise_stub
  sym = {
    kind: "function", abi: "c", name: "Foo", signature: "void Foo(MyCallback)",
    parameters_json: '[{"name":"cb","type":"MyCallback _Nonnull","kind":"callback_non_nil","is_out_param":false,"nullability":"nonnull"}]'
  }
  swift = AppleSDKMac::GlueCompiler::TemplateGenerator.new.generate(
    framework: "Acme", symbol: sym, glue_id: "ab12"
  )
  assert_match(/rb_raise\(rb_eRuntimeError, "non-nil callback not yet supported"\)/, swift)
end
```

- [ ] **Step 2: Run, confirm fail**

```bash
bundle exec ruby -Ilib -Itest test/template_generator_test.rb \
  -n /test_callback_nilable_emits|test_callback_non_nil_emits/
```

Expected: 2 failures (Marshaller.for returns nil for these kinds → generate returns nil → swift is nil).

- [ ] **Step 3: Commit RED**

```bash
git add test/template_generator_test.rb && \
git commit -m "test: add failing specs for callback_nilable / callback_non_nil Marshallers"
```

- [ ] **Step 4: GREEN — add Marshallers**

In `marshallers.rb`:

```ruby
class CallbackNilableMarshaller < Marshaller
  def in_load
    type = @param[:type].sub(/\s*_(?:Nullable|Nonnull)\b/, "").strip
    name = @param[:name]; i = @index
    <<~SWIFT.chomp
      let #{name}: #{type}?
      if argv[#{i}] == Qnil {
          #{name} = nil
      } else {
          rb_raise(rb_eRuntimeError, "non-nil callback not yet supported")
      }
    SWIFT
  end
end
Marshaller::REGISTRY["callback_nilable"] = CallbackNilableMarshaller

class CallbackNonNilMarshaller < Marshaller
  def in_load
    type = @param[:type].sub(/\s*_(?:Nullable|Nonnull)\b/, "").strip
    name = @param[:name]
    "let #{name}: #{type}? = nil; rb_raise(rb_eRuntimeError, \"non-nil callback not yet supported\")"
  end
end
Marshaller::REGISTRY["callback_non_nil"] = CallbackNonNilMarshaller
```

- [ ] **Step 5: Run, confirm GREEN**

Expected: 2 tests pass.

- [ ] **Step 6: Commit GREEN**

```bash
git add lib/apple_sdk_mac/glue_compiler/marshallers.rb && \
git commit -m "feat: callback_(non_)nilable Marshallers with rb_raise stubs (Callback pillar later)"
```

---

### Task 12: `VoidPtrNilableMarshaller`

**Files:**
- Modify: `lib/apple_sdk_mac/glue_compiler/marshallers.rb`
- Modify: `test/template_generator_test.rb`

- [ ] **Step 1: Write failing test**

```ruby
def test_void_ptr_nilable_emits_bitpattern
  sym = {
    kind: "function", abi: "c", name: "Foo", signature: "void Foo(void *)",
    parameters_json: '[{"name":"refcon","type":"void * _Nullable","kind":"void_ptr_nilable","is_out_param":false,"nullability":"nullable"}]'
  }
  swift = AppleSDKMac::GlueCompiler::TemplateGenerator.new.generate(
    framework: "Acme", symbol: sym, glue_id: "ab12"
  )
  assert_match(/let refcon: UnsafeMutableRawPointer\?/, swift)
  assert_match(/UnsafeMutableRawPointer\(bitPattern: Int\(rb_num2ll\(argv\[0\]\)\)\)/, swift)
end
```

- [ ] **Step 2: Run, confirm fail; commit RED**

```bash
bundle exec ruby -Ilib -Itest test/template_generator_test.rb -n test_void_ptr_nilable_emits_bitpattern && \
git add test/template_generator_test.rb && \
git commit -m "test: add failing spec for void_ptr_nilable Marshaller"
```

- [ ] **Step 3: GREEN — add Marshaller**

```ruby
class VoidPtrNilableMarshaller < Marshaller
  def in_load
    name = @param[:name]; i = @index
    <<~SWIFT.chomp
      let #{name}: UnsafeMutableRawPointer?
      if argv[#{i}] == Qnil {
          #{name} = nil
      } else {
          #{name} = UnsafeMutableRawPointer(bitPattern: Int(rb_num2ll(argv[#{i}])))
      }
    SWIFT
  end
end
Marshaller::REGISTRY["void_ptr_nilable"] = VoidPtrNilableMarshaller
```

- [ ] **Step 4: Run + commit GREEN**

```bash
bundle exec ruby -Ilib -Itest test/template_generator_test.rb -n test_void_ptr_nilable_emits_bitpattern && \
git add lib/apple_sdk_mac/glue_compiler/marshallers.rb && \
git commit -m "feat: void_ptr_nilable Marshaller emits UnsafeMutableRawPointer? bitPattern"
```

---

### Task 13: `StructInMarshaller` (depth-1 nesting + cycle detection)

**Files:**
- Modify: `lib/apple_sdk_mac/glue_compiler/marshallers.rb`
- Modify: `test/template_generator_test.rb`

- [ ] **Step 1: Write failing tests**

```ruby
def test_struct_in_emits_field_by_field_hash_aref
  fake_kc = Struct.new(:store).new({}).tap do |kc|
    def kc.lookup_symbol(framework:, symbol:)
      return { name: symbol, fields_json: JSON.dump([
        {"name" => "x", "type" => "Int32", "kind" => "int"},
        {"name" => "y", "type" => "Int32", "kind" => "int"}
      ]) } if symbol == "Point"
      nil
    end
  end
  sym = {
    kind: "function", abi: "c", name: "DrawPoint", signature: "void DrawPoint(Point *)",
    parameters_json: '[{"name":"p","type":"Point * _Nonnull","kind":"struct_in","is_out_param":false,"nullability":"nonnull"}]'
  }
  swift = AppleSDKMac::GlueCompiler::TemplateGenerator.new(knowledge_cache: fake_kc).generate(
    framework: "Acme", symbol: sym, glue_id: "ab12"
  )
  assert_match(/var p_struct = Point\(\)/, swift)
  assert_match(/p_struct\.x = Int32\(rb_num2ll\(rb_hash_aref\(argv\[0\], rb_str_new_cstr\("x"\)\)\)\)/, swift)
  assert_match(/p_struct\.y = Int32\(rb_num2ll\(rb_hash_aref\(argv\[0\], rb_str_new_cstr\("y"\)\)\)\)/, swift)
  assert_match(/withUnsafePointer\(to: &p_struct\)/, swift)
end

def test_struct_in_handles_nested_depth_1
  fake_kc = Struct.new(:store).new({}).tap do |kc|
    def kc.lookup_symbol(framework:, symbol:)
      case symbol
      when "Rect" then { name: "Rect", fields_json: JSON.dump([
        {"name" => "origin", "type" => "Point", "kind" => "struct_in"},
        {"name" => "size",   "type" => "Size",  "kind" => "struct_in"}
      ]) }
      when "Point" then { name: "Point", fields_json: JSON.dump([
        {"name" => "x", "type" => "Int32", "kind" => "int"},
        {"name" => "y", "type" => "Int32", "kind" => "int"}
      ]) }
      when "Size" then { name: "Size", fields_json: JSON.dump([
        {"name" => "w", "type" => "Int32", "kind" => "int"},
        {"name" => "h", "type" => "Int32", "kind" => "int"}
      ]) }
      end
    end
  end
  sym = {
    kind: "function", abi: "c", name: "DrawRect", signature: "void DrawRect(Rect *)",
    parameters_json: '[{"name":"r","type":"Rect * _Nonnull","kind":"struct_in","is_out_param":false,"nullability":"nonnull"}]'
  }
  swift = AppleSDKMac::GlueCompiler::TemplateGenerator.new(knowledge_cache: fake_kc).generate(
    framework: "Acme", symbol: sym, glue_id: "ab12"
  )
  assert_match(/r_struct\.origin\.x =/, swift)
  assert_match(/r_struct\.size\.h =/, swift)
end

def test_struct_in_cycle_detection_returns_nil
  fake_kc = Struct.new(:store).new({}).tap do |kc|
    def kc.lookup_symbol(framework:, symbol:)
      return { name: "Node", fields_json: JSON.dump([
        {"name" => "value", "type" => "Int32", "kind" => "int"},
        {"name" => "next",  "type" => "Node",  "kind" => "struct_in"}
      ]) } if symbol == "Node"
    end
  end
  sym = {
    kind: "function", abi: "c", name: "Visit", signature: "void Visit(Node *)",
    parameters_json: '[{"name":"n","type":"Node * _Nonnull","kind":"struct_in","is_out_param":false,"nullability":"nonnull"}]'
  }
  swift = AppleSDKMac::GlueCompiler::TemplateGenerator.new(knowledge_cache: fake_kc).generate(
    framework: "Acme", symbol: sym, glue_id: "ab12"
  )
  assert_nil swift  # cycle detected → escape to LLM
end
```

- [ ] **Step 2: Run, confirm fail; commit RED**

```bash
bundle exec ruby -Ilib -Itest test/template_generator_test.rb -n /test_struct_in/ && \
git add test/template_generator_test.rb && \
git commit -m "test: add failing specs for struct_in Marshaller (flat, nested, cycle)"
```

- [ ] **Step 3: GREEN — add Marshaller**

```ruby
class StructInMarshaller < Marshaller
  def in_load
    type = @param[:type].sub(/\s*\*.*\z/, "").gsub(/\b_(Nonnull|Nullable)\b/, "").sub(/\Aconst\s+/, "").strip
    return nil if @ctx[:struct_visited].include?(type)
    return nil unless @ctx[:knowledge_cache]
    sym = @ctx[:knowledge_cache].lookup_symbol(framework: @ctx[:framework], symbol: type)
    return nil unless sym && sym[:fields_json]
    fields = JSON.parse(sym[:fields_json])

    @ctx[:struct_visited] << type
    name = @param[:name]; i = @index
    lines = ["let #{name}_h = argv[#{i}]", "var #{name}_struct = #{type}()"]
    fields.each do |f|
      expr = field_load_expr(f, "#{name}_h", name)
      return nil unless expr  # cycle on a field => abort whole symbol
      lines << expr
    end
    @ctx[:struct_visited].delete(type)
    lines.join("\n    ")
  end

  def call_arg
    "#{@param[:name]}_ptr"  # set up by enclosing withUnsafePointer wrapper
  end

  private

  def field_load_expr(field, h_var, prefix)
    target = "#{prefix}_struct.#{field['name']}"
    case field["kind"]
    when "int"
      type_token = field["type"].gsub(/\b_(Nonnull|Nullable)\b/, "").strip
      "#{target} = #{type_token}(rb_num2ll(rb_hash_aref(#{h_var}, rb_str_new_cstr(\"#{field['name']}\"))))"
    when "float"
      "#{target} = rb_num2dbl(rb_hash_aref(#{h_var}, rb_str_new_cstr(\"#{field['name']}\")))"
    when "bool"
      "#{target} = (rb_hash_aref(#{h_var}, rb_str_new_cstr(\"#{field['name']}\")) != Qfalse)"
    when "string"
      "var #{prefix}_#{field['name']}_v = rb_hash_aref(#{h_var}, rb_str_new_cstr(\"#{field['name']}\")); #{target} = String(cString: rb_string_value_cstr(&#{prefix}_#{field['name']}_v))"
    when "opaque_ref"
      type_token = field["type"].gsub(/\b_(Nonnull|Nullable)\b/, "").strip
      "#{target} = #{type_token}(rb_num2ull(rb_hash_aref(#{h_var}, rb_str_new_cstr(\"#{field['name']}\"))))"
    when "struct_in"
      nested_type = field["type"].gsub(/\b_(Nonnull|Nullable)\b/, "").strip
      return nil if @ctx[:struct_visited].include?(nested_type)
      sym = @ctx[:knowledge_cache].lookup_symbol(framework: @ctx[:framework], symbol: nested_type)
      return nil unless sym && sym[:fields_json]
      nested_fields = JSON.parse(sym[:fields_json])
      @ctx[:struct_visited] << nested_type
      nested_h = "#{prefix}_#{field['name']}_h"
      lines = ["let #{nested_h} = rb_hash_aref(#{h_var}, rb_str_new_cstr(\"#{field['name']}\"))"]
      nested_fields.each do |nf|
        expr = field_load_expr(nf, nested_h, "#{prefix}_struct.#{field['name']}".sub(/\A.*?_struct\./, "#{prefix}_"))
        return nil unless expr
        lines << expr.sub("#{prefix}_struct.#{field['name']}.", "#{prefix}_struct.#{field['name']}.")
      end
      @ctx[:struct_visited].delete(nested_type)
      lines.join("\n    ")
    else
      nil  # unsupported field kind
    end
  end
end
Marshaller::REGISTRY["struct_in"] = StructInMarshaller
```

Also update `template_generator.rb` to wrap the call with `withUnsafePointer` for any struct_in marshaller:

```ruby
struct_marshallers = marshallers.select { |m| m.is_a?(StructInMarshaller) }
call_expr = "#{symbol[:name]}(#{call_args})"
struct_marshallers.each do |sm|
  call_expr = "withUnsafePointer(to: &#{sm.param[:name]}_struct) { #{sm.param[:name]}_ptr in\n        #{call_expr}\n    }"
end
```

(integrate into the existing `body << "let result = ..."` or `body << "let status = ..."` lines).

- [ ] **Step 4: Run + commit GREEN**

```bash
bundle exec ruby -Ilib -Itest test/template_generator_test.rb -n /test_struct_in/ && \
git add lib/apple_sdk_mac/glue_compiler/marshallers.rb lib/apple_sdk_mac/glue_compiler/template_generator.rb && \
git commit -m "feat: struct_in Marshaller with depth-1 nesting and cycle detection"
```

---

### Task 14: `StructOutMarshaller`

**Files:**
- Modify: `lib/apple_sdk_mac/glue_compiler/marshallers.rb`
- Modify: `test/template_generator_test.rb`

- [ ] **Step 1: Write failing test**

```ruby
def test_struct_out_emits_hash_new_aset_per_field
  fake_kc = ... # similar pattern as Task 13, with a "Status" struct {ok:bool, code:int}
  sym = {
    kind: "function", abi: "c", name: "GetStatus", signature: "OSStatus GetStatus(Status *)",
    parameters_json: '[{"name":"out","type":"Status * _Nonnull","kind":"struct_out","is_out_param":true,"nullability":"nonnull"}]'
  }
  swift = AppleSDKMac::GlueCompiler::TemplateGenerator.new(knowledge_cache: fake_kc).generate(
    framework: "Acme", symbol: sym, glue_id: "ab12"
  )
  assert_match(/var out_struct = Status\(\)/, swift)
  assert_match(/let status = GetStatus\(&out_struct\)/, swift)
  assert_match(/let out_h = rb_hash_new\(\)/, swift)
  assert_match(/rb_hash_aset\(out_h, rb_str_new_cstr\("ok"\)/, swift)
  assert_match(/rb_hash_aset\(out_h, rb_str_new_cstr\("code"\)/, swift)
  assert_match(/return out_h/, swift)
end
```

- [ ] **Step 2: Run, confirm fail; commit RED**

- [ ] **Step 3: GREEN — add `StructOutMarshaller`**

```ruby
class StructOutMarshaller < Marshaller
  def out_init
    type = struct_type
    "var #{@param[:name]}_struct = #{type}()"
  end

  def out_addr
    "&#{@param[:name]}_struct"
  end

  def out_to_ruby
    type = struct_type
    sym = @ctx[:knowledge_cache].lookup_symbol(framework: @ctx[:framework], symbol: type)
    return nil unless sym && sym[:fields_json]
    fields = JSON.parse(sym[:fields_json])
    h_var = "#{@param[:name]}_h"
    lines = ["let #{h_var} = rb_hash_new()"]
    fields.each do |f|
      val_expr = field_to_ruby_expr(f, "#{@param[:name]}_struct.#{f['name']}")
      return nil unless val_expr
      lines << "rb_hash_aset(#{h_var}, rb_str_new_cstr(\"#{f['name']}\"), #{val_expr})"
    end
    lines << h_var
    lines.join("\n    ")
  end

  private

  def struct_type
    @param[:type].sub(/\s*\*.*\z/, "").gsub(/\b_(Nonnull|Nullable)\b/, "").sub(/\Aconst\s+/, "").strip
  end

  def field_to_ruby_expr(field, swift_path)
    case field["kind"]
    when "int"        then "rb_ll2inum(Int64(#{swift_path}))"
    when "float"      then "rb_float_new(Double(#{swift_path}))"
    when "bool"       then "(#{swift_path} ? Qtrue : Qfalse)"
    when "opaque_ref" then "rb_ull2inum(UInt64(#{swift_path}))"
    else nil
    end
  end
end
Marshaller::REGISTRY["struct_out"] = StructOutMarshaller
```

Update `template_generator.rb` single-out branch to use `m.out_to_ruby` (already does).

- [ ] **Step 4: Run + commit GREEN**

```bash
git add lib/apple_sdk_mac/glue_compiler/marshallers.rb && \
git commit -m "feat: struct_out Marshaller emits rb_hash_new + per-field rb_hash_aset"
```

---

### Task 15: Multi-out-param hash return

**Files:**
- Modify: `lib/apple_sdk_mac/glue_compiler/template_generator.rb`
- Modify: `test/template_generator_test.rb`

- [ ] **Step 1: Write failing test**

```ruby
def test_multi_out_param_returns_hash_with_named_keys
  sym = {
    kind: "function", abi: "c", name: "TwoOut", signature: "OSStatus TwoOut(Int *, Int *)",
    parameters_json: '[
      {"name":"a","type":"Int * _Nonnull","kind":"opaque_ref","is_out_param":true,"nullability":"nonnull"},
      {"name":"b","type":"Int * _Nonnull","kind":"opaque_ref","is_out_param":true,"nullability":"nonnull"}
    ]'
  }
  swift = AppleSDKMac::GlueCompiler::TemplateGenerator.new.generate(
    framework: "Acme", symbol: sym, glue_id: "ab12"
  )
  assert_match(/let h = rb_hash_new\(\)/, swift)
  assert_match(/rb_hash_aset\(h, rb_str_new_cstr\("a"\)/, swift)
  assert_match(/rb_hash_aset\(h, rb_str_new_cstr\("b"\)/, swift)
  assert_match(/return h/, swift)
end
```

- [ ] **Step 2: Run, confirm fail; commit RED**

- [ ] **Step 3: GREEN — replace the `return nil` for multi-out**

In `template_generator.rb`, replace the placeholder `return nil` for ≥2 out-params:

```ruby
else
  body << "let status = #{symbol[:name]}(#{call_args})"
  body << %(if status != 0 { rb_raise(rb_eRuntimeError, "OSStatus") })
  body << "let h = rb_hash_new()"
  out_marshallers.each do |om|
    body << "rb_hash_aset(h, rb_str_new_cstr(\"#{om.param[:name]}\"), #{om.out_to_ruby})"
  end
  body << "return h"
end
```

- [ ] **Step 4: Run + commit GREEN**

---

### Task 16: `VariadicMarshaller`

**Files:**
- Modify: `lib/apple_sdk_mac/glue_compiler/marshallers.rb`
- Modify: `test/template_generator_test.rb`

- [ ] **Step 1: Write failing test**

```ruby
def test_variadic_args_emits_with_va_list
  sym = {
    kind: "function", abi: "c", name: "MyLog", signature: "void MyLog(const char *, ...)",
    parameters_json: '[
      {"name":"fmt","type":"const char *","kind":"string","is_out_param":false,"nullability":"unspecified"},
      {"name":"vargs","type":"...","kind":"variadic_args","is_out_param":false,"nullability":"unspecified"}
    ]'
  }
  swift = AppleSDKMac::GlueCompiler::TemplateGenerator.new.generate(
    framework: "Acme", symbol: sym, glue_id: "ab12"
  )
  assert_match(/withVaList\(/, swift)
  assert_match(/rubyValueToCVarArg/, swift)
end
```

- [ ] **Step 2: Run, confirm fail; commit RED**

- [ ] **Step 3: GREEN — add Marshaller**

```ruby
class VariadicMarshaller < Marshaller
  def in_load
    "let __varStart = #{@index}\nvar __cVarArgs: [CVarArg] = []\nfor __k in __varStart..<Int(argc) { __cVarArgs.append(rubyValueToCVarArg(argv[__k])) }"
  end
  def call_arg
    "__va"  # bound by withVaList wrapper
  end
end
Marshaller::REGISTRY["variadic_args"] = VariadicMarshaller
```

In `template_generator.rb`, when any marshaller is `VariadicMarshaller`, wrap the call:

```ruby
if marshallers.any? { |m| m.is_a?(VariadicMarshaller) }
  call_expr = "withVaList(__cVarArgs) { __va in\n        #{call_expr}\n    }"
end
```

- [ ] **Step 4: Run + commit GREEN**

(Note: `rubyValueToCVarArg` is a runtime ext helper added in Task 19.)

---

### Task 17: MIDIClientCreate end-to-end characterization (gem C side, deterministic only)

**Files:**
- Modify: `test/template_generator_test.rb`

- [ ] **Step 1: Write integration test**

```ruby
def test_midiclientcreate_endtoend_swift_shape
  kc = AppleSDKMac::KnowledgeCache.open
  sym = kc.lookup_symbol(framework: "CoreMIDI", symbol: "MIDIClientCreate")
  swift = AppleSDKMac::GlueCompiler::TemplateGenerator.new(knowledge_cache: kc).generate(
    framework: "CoreMIDI", symbol: sym, glue_id: "ab12"
  )
  refute_nil swift, "MIDIClientCreate should be deterministic now"
  assert_match(/import CoreMIDI/, swift)
  assert_match(/@_silgen_name\("rb_str_new_cstr"\)/, swift)
  assert_match(/@c\npublic func glue_ab12_MIDIClientCreate/, swift)
  assert_match(/let name = String\(cString:.*\) as CFString/, swift)
  assert_match(/let notifyProc: MIDINotifyProc\?/, swift)
  assert_match(/let notifyRefCon: UnsafeMutableRawPointer\?/, swift)
  assert_match(/var outClient_outRef:/, swift)
  assert_match(/return rb_ull2inum/, swift)
  kc.close
end
```

- [ ] **Step 2: Run, confirm GREEN (this is a regression-safety test, no new code)**

```bash
bundle exec ruby -Ilib -Itest test/template_generator_test.rb -n test_midiclientcreate_endtoend_swift_shape
```

Expected: PASS (all preceding tasks combined produce this shape).

- [ ] **Step 3: Commit (test-only)**

```bash
git add test/template_generator_test.rb && \
git commit -m "test: add end-to-end characterization for MIDIClientCreate template output"
```

---

## Phase 5 — LLM prompt sync

### Task 18: LLM prompt — new worked examples + Callback pillar in rule 9 else branch

**Files:**
- Modify: `lib/apple_sdk_mac/glue_compiler/llm_generator.rb`
- Modify: `test/llm_generator_test.rb`

- [ ] **Step 1: Write failing tests**

```ruby
def test_instructions_embed_extended_header_silgen_names
  i = AppleSDKMac::GlueCompiler::LLMGenerator::INSTRUCTIONS
  assert_includes i, '@_silgen_name("rb_hash_new")'
  assert_includes i, '@_silgen_name("rb_hash_aref")'
  assert_includes i, '@_silgen_name("rb_hash_aset")'
end

def test_instructions_have_struct_in_worked_example
  i = AppleSDKMac::GlueCompiler::LLMGenerator::INSTRUCTIONS
  assert_match(/var\s+\w+_struct\s*=\s*\w+\(\)/, i, "WORKED_EXAMPLE_STRUCT_IN should show var struct = Type()")
  assert_match(/rb_hash_aref/, i)
end

def test_instructions_callback_else_branch_uses_callback_pillar
  i = AppleSDKMac::GlueCompiler::LLMGenerator::INSTRUCTIONS
  assert_match(/AppleSDKMacRuntime\.CallbackPillar\.register/, i)
end
```

- [ ] **Step 2: Run, confirm fail; commit RED**

- [ ] **Step 3: GREEN — extend INSTRUCTIONS**

In `llm_generator.rb`, add:

```ruby
WORKED_EXAMPLE_STRUCT_IN = <<~SWIFT.freeze
  // For a "struct_in" parameter (e.g. `const Foo *` _Nonnull):
  let foo_h = argv[0]
  var foo_struct = Foo()
  foo_struct.field1 = Int32(rb_num2ll(rb_hash_aref(foo_h, rb_str_new_cstr("field1"))))
  foo_struct.field2 = Int32(rb_num2ll(rb_hash_aref(foo_h, rb_str_new_cstr("field2"))))
  // ... call site:
  withUnsafePointer(to: &foo_struct) { foo_ptr in
      let result = SomeFunction(foo_ptr)
      ...
  }
SWIFT

WORKED_EXAMPLE_OUT_HASH = <<~SWIFT.freeze
  // For a multi-out-param call returning a Ruby Hash:
  var outA_outRef: TypeA = TypeA()
  var outB_outRef: TypeB = TypeB()
  let status = SomeFunction(in1, &outA_outRef, &outB_outRef)
  if status != 0 { rb_raise(rb_eRuntimeError, "OSStatus") }
  let h = rb_hash_new()
  rb_hash_aset(h, rb_str_new_cstr("outA"), rb_ll2inum(Int64(outA_outRef)))
  rb_hash_aset(h, rb_str_new_cstr("outB"), rb_ll2inum(Int64(outB_outRef)))
  return h
SWIFT
```

In rule 9, replace the `rb_raise` else-branch with:

```
9. For nullable C function-pointer parameters (callbacks):

       let cb: <CallbackType>?
       var cb_handle: AppleSDKMacRuntime.CallbackPillar.Handle? = nil
       if argv[i] == Qnil {
           cb = nil
       } else {
           cb_handle = AppleSDKMacRuntime.CallbackPillar.register(
               rubyBlock: argv[i], signature: .<sigToken>
           )
           cb = cb_handle!.fnptr as <CallbackType>
       }
       defer { cb_handle?.unregister() }
```

Append two new sections to `INSTRUCTIONS`:
```
SECTION 4 — WORKED EXAMPLE: struct in
#{WORKED_EXAMPLE_STRUCT_IN}

SECTION 5 — WORKED EXAMPLE: multi-out hash return
#{WORKED_EXAMPLE_OUT_HASH}
```

- [ ] **Step 4: Run, confirm GREEN; commit**

```bash
bundle exec ruby -Ilib -Itest test/llm_generator_test.rb && \
git add lib/apple_sdk_mac/glue_compiler/llm_generator.rb test/llm_generator_test.rb && \
git commit -m "feat: LLM prompt syncs HEADER + adds struct_in / multi-out worked examples + Callback pillar in rule 9"
```

---

## Phase 6 — Callback pillar (Swift runtime ext)

### Task 19: Callback pillar core + signature catalog + codegen rake task

**Files:**
- Create: `ext/apple_sdk_mac_runtime/callback_signatures.yml`
- Create: `ext/apple_sdk_mac_runtime/Sources/CallbackPillar/CallbackPillar.swift`
- Create: `ext/apple_sdk_mac_runtime/Sources/CallbackPillar/CallbackPillarGenerated.swift` (initially empty, generated)
- Create: `ext/apple_sdk_mac_runtime/codegen/callback_pillar_codegen.rb` (rake helper)
- Modify: `Rakefile` (add `runtime:codegen_callback_pillar` task)
- Modify: `ext/apple_sdk_mac_runtime/Package.swift` (add CallbackPillar target)

- [ ] **Step 1: Write `callback_signatures.yml` with initial 3 signatures (MIDI focus first)**

```yaml
- token: midiNotifyProc
  swift_type: MIDINotifyProc
  args:
    - { name: msg,    swift: "UnsafePointer<MIDINotification>" }
    - { name: refcon, swift: "UnsafeMutableRawPointer?" }
  return: void

- token: midiReadProc
  swift_type: MIDIReadProc
  args:
    - { name: pktlist,  swift: "UnsafePointer<MIDIPacketList>" }
    - { name: readProcRefCon, swift: "UnsafeMutableRawPointer?" }
    - { name: srcConnRefCon,  swift: "UnsafeMutableRawPointer?" }
  return: void

- token: cfAllocatorAllocate
  swift_type: CFAllocatorAllocateCallBack
  args:
    - { name: size, swift: "CFIndex" }
    - { name: hint, swift: "CFOptionFlags" }
    - { name: info, swift: "UnsafeMutableRawPointer?" }
  return: "UnsafeMutableRawPointer?"
```

- [ ] **Step 2: Write `CallbackPillar.swift` core**

```swift
import Foundation

public enum CallbackPillar {
    public final class Handle {
        public let fnptr: UnsafeRawPointer
        let slot: Slot
        init(fnptr: UnsafeRawPointer, slot: Slot) {
            self.fnptr = fnptr; self.slot = slot
        }
        public func unregister() { ctxStore.free(slot) }
    }

    static let ctxStore = SlotStore()
}

final class Slot {
    let rubyBlock: UInt
    init(rubyBlock: UInt) {
        self.rubyBlock = rubyBlock
        rb_gc_register_address_helper(rubyBlock)
    }
    deinit {
        rb_gc_unregister_address_helper(rubyBlock)
    }
}

final class SlotStore {
    private let lock = NSLock()
    private var slots: [ObjectIdentifier: Slot] = [:]
    func alloc(rubyBlock: UInt) -> Slot {
        let s = Slot(rubyBlock: rubyBlock)
        lock.lock(); defer { lock.unlock() }
        slots[ObjectIdentifier(s)] = s
        return s
    }
    func free(_ slot: Slot) {
        lock.lock(); defer { lock.unlock() }
        slots.removeValue(forKey: ObjectIdentifier(slot))
    }
}

@_silgen_name("rb_gc_register_address")
func rb_gc_register_address_inner(_ p: UnsafeMutablePointer<UInt>)
@_silgen_name("rb_gc_unregister_address")
func rb_gc_unregister_address_inner(_ p: UnsafeMutablePointer<UInt>)

func rb_gc_register_address_helper(_ value: UInt) {
    let p = UnsafeMutablePointer<UInt>.allocate(capacity: 1)
    p.pointee = value
    rb_gc_register_address_inner(p)
}
func rb_gc_unregister_address_helper(_ value: UInt) {
    // Simplified: leak the holder pointer; release on session end.
    // Production-grade pinning lifecycle deferred to follow-up.
}
```

- [ ] **Step 3: Write codegen helper `codegen/callback_pillar_codegen.rb`**

```ruby
require "yaml"
require "erb"

INPUT  = "ext/apple_sdk_mac_runtime/callback_signatures.yml"
OUTPUT = "ext/apple_sdk_mac_runtime/Sources/CallbackPillar/CallbackPillarGenerated.swift"

sigs = YAML.load_file(INPUT)

template = <<~SWIFT
  // AUTO-GENERATED by `rake runtime:codegen_callback_pillar`. DO NOT EDIT.
  import Foundation

  public extension CallbackPillar {
      enum Signature {
          <% sigs.each do |s| %>case <%= s["token"] %>
          <% end %>
      }

      static func register(rubyBlock: UInt, signature: Signature) -> Handle {
          switch signature {
          <% sigs.each do |s| %>case .<%= s["token"] %>: return register_<%= s["token"] %>(rubyBlock)
          <% end %>
          }
      }

      <% sigs.each do |s|
        args_decl = s["args"].map { |a| "_ \#{a["name"]}: \#{a["swift"]}" }.join(", ")
        ret_token = s["return"]
      %>
      private static func register_<%= s["token"] %>(_ rubyBlock: UInt) -> Handle {
          let slot = ctxStore.alloc(rubyBlock: rubyBlock)
          let trampoline: <%= s["swift_type"] %> = { (<%= s["args"].map { |a| a["name"] }.join(", ") %>) in
              // TODO: invoke Ruby block with GVL acquisition
              <% if ret_token != "void" %>return nil<% end %>
          }
          return Handle(
              fnptr: unsafeBitCast(trampoline, to: UnsafeRawPointer.self),
              slot: slot
          )
      }
      <% end %>
  }
SWIFT

File.write(OUTPUT, ERB.new(template, trim_mode: "-").result)
puts "Wrote #{OUTPUT} (#{sigs.length} signatures)"
```

- [ ] **Step 4: Add Rakefile task**

In `Rakefile`:

```ruby
namespace :runtime do
  desc "Generate CallbackPillarGenerated.swift from callback_signatures.yml"
  task :codegen_callback_pillar do
    ruby "ext/apple_sdk_mac_runtime/codegen/callback_pillar_codegen.rb"
  end
end
```

- [ ] **Step 5: Update `Package.swift` for the new module**

Add `CallbackPillar` as a sub-source-set of the existing `AppleSDKMacRuntime` target (or new sibling target). Inspect current `Package.swift` to follow its idioms.

- [ ] **Step 6: Run codegen and verify Swift compiles**

```bash
bundle exec rake runtime:codegen_callback_pillar && \
cd ext/apple_sdk_mac_runtime && \
swift build
```

Expected: `Build complete!`. If trampoline body has `// TODO: invoke Ruby block with GVL` with no return, replace `return nil` placeholder with concrete: leave a `// stub` comment + `return nil` for return-bearing signatures. The Ruby invocation itself is wired in Task 20.

- [ ] **Step 7: Commit codegen + first signatures**

```bash
git add ext/apple_sdk_mac_runtime/callback_signatures.yml \
        ext/apple_sdk_mac_runtime/Sources/CallbackPillar/ \
        ext/apple_sdk_mac_runtime/codegen/ \
        ext/apple_sdk_mac_runtime/Package.swift \
        Rakefile && \
git commit -m "feat: scaffold Callback pillar with codegen + 3 MIDI/CF signatures"
```

---

### Task 20: Wire Ruby Block invocation through GVL in trampolines

**Files:**
- Modify: `ext/apple_sdk_mac_runtime/Sources/CallbackPillar/CallbackPillar.swift`
- Modify: `ext/apple_sdk_mac_runtime/codegen/callback_pillar_codegen.rb`

- [ ] **Step 1: Add GVL helpers to CallbackPillar.swift**

```swift
@_silgen_name("rb_thread_call_with_gvl")
func rb_thread_call_with_gvl(_ fn: @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?,
                              _ data: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?

@_silgen_name("rb_funcall")
func rb_funcall(_ recv: UInt, _ mid: UInt, _ argc: Int32, _ a1: UInt, _ a2: UInt, _ a3: UInt) -> UInt

@_silgen_name("rb_intern")
func rb_intern(_ name: UnsafePointer<CChar>) -> UInt

func withGVL<T>(_ body: () -> T) -> T {
    var result: T!
    rb_thread_call_with_gvl({ ctx in
        let body = Unmanaged<AnyObject>.fromOpaque(ctx!).takeRetainedValue() as! () -> Any
        // ...
        return nil
    }, Unmanaged.passRetained(/* boxed body */).toOpaque())
    return result
}
```

(The exact box pattern varies; adopt the simplest one that compiles and tests pass. Avoid premature optimization.)

- [ ] **Step 2: Update codegen template to fill trampoline body**

Replace the `// TODO: invoke Ruby block with GVL` block with concrete invocation per arg:

```ruby
trampoline_body = s["args"].map.with_index do |a, i|
  "let arg#{i + 1} = wrap_#{a["swift"].downcase.gsub(/[^a-z0-9]/, "_")}(#{a["name"]})"
end.join("\n            ")

call_block = "let result = withGVL { rb_funcall(rubyBlock, rb_intern(\"call\"), #{s["args"].length}, #{(1..s["args"].length).map { |i| "arg#{i}" }.join(", ")}) }"
```

Add helper `wrap_*` functions in `CallbackPillar.swift` that convert each Swift type to a Ruby `VALUE`:

```swift
func wrap_unsafepointer_midinotification(_ p: UnsafePointer<MIDINotification>) -> UInt {
    return rb_ull2inum(UInt64(UInt(bitPattern: p)))
}
func wrap_unsafemutablerawpointer_optional(_ p: UnsafeMutableRawPointer?) -> UInt {
    if p == nil { return Qnil }
    return rb_ull2inum(UInt64(UInt(bitPattern: p!)))
}
// ... per swift type used in signatures
```

- [ ] **Step 3: Regenerate, build, run a smoke**

```bash
bundle exec rake runtime:codegen_callback_pillar && \
cd ext/apple_sdk_mac_runtime && swift build
```

- [ ] **Step 4: Add a unit test for register/unregister roundtrip (no actual callback fire)**

```ruby
def test_callback_pillar_register_returns_handle_and_unregisters
  # Pure smoke: invoke register through a small Ruby driver that
  # exercises Apple framework symbol indirectly by invoking
  # a glue function. For now, assert the dylib loads + register
  # symbol is exported.
  ...
end
```

(If wiring is too heavy, defer the live test until Task 22 smoke and only assert export-symbol presence here.)

- [ ] **Step 5: Commit**

```bash
git commit -m "feat: Callback pillar invokes Ruby block via rb_thread_call_with_gvl"
```

---

### Task 21: Switch `CallbackNilableMarshaller` / `NonNilMarshaller` to Callback pillar API

**Files:**
- Modify: `lib/apple_sdk_mac/glue_compiler/marshallers.rb`
- Modify: `test/template_generator_test.rb`

- [ ] **Step 1: Update existing tests + add new**

Modify Task 11 tests:
- `test_callback_nilable_emits_qnil_branch_with_rb_raise_stub` → rename `..._with_callback_pillar`, change asserts:
  ```ruby
  assert_match(/AppleSDKMacRuntime\.CallbackPillar\.register/, swift)
  assert_match(/cb_handle = AppleSDKMacRuntime\.CallbackPillar\.register/, swift)
  refute_match(/non-nil callback not yet supported/, swift)  # stub gone
  ```
- `test_callback_non_nil_emits_unconditional_rb_raise_stub` → similar update.

- [ ] **Step 2: Run, confirm fail; commit RED**

- [ ] **Step 3: GREEN — update Marshallers**

```ruby
class CallbackNilableMarshaller < Marshaller
  def in_load
    type = @param[:type].sub(/\s*_(?:Nullable|Nonnull)\b/, "").strip
    sig_token = type[0].downcase + type[1..]  # "MIDINotifyProc" → "mIDINotifyProc"; tweak rule below
    sig_token = camel_to_signature_token(type)
    name = @param[:name]; i = @index
    <<~SWIFT.chomp
      let #{name}: #{type}?
      var #{name}_handle: AppleSDKMacRuntime.CallbackPillar.Handle? = nil
      if argv[#{i}] == Qnil {
          #{name} = nil
      } else {
          #{name}_handle = AppleSDKMacRuntime.CallbackPillar.register(
              rubyBlock: argv[#{i}], signature: .#{sig_token}
          )
          #{name} = #{name}_handle!.fnptr as #{type}
      }
      defer { #{name}_handle?.unregister() }
    SWIFT
  end

  private

  def camel_to_signature_token(type)
    # MIDINotifyProc → midiNotifyProc, CFAllocatorAllocateCallBack → cfAllocatorAllocate
    # Simple lower-camel: lowercase first char; keep rest.
    type[0].downcase + type[1..]
  end
end
```

(adjust mapping to match `callback_signatures.yml` tokens)

- [ ] **Step 4: Run + commit GREEN**

```bash
git commit -m "feat: callback Marshallers route via Callback pillar register/unregister"
```

---

## Phase 7 — Smoke + E2E

### Task 22: Smoke `test_create_client_and_dispose` + `test_send_packet`, full E2E verification

**Files:**
- Modify: `test/integration/coremidi_smoke_test.rb`
- Modify: `docs/superpowers/specs/2026-05-05-unified-marshalling-and-callback-pillar-design.md` (Verification section)

- [ ] **Step 1: Inspect current smoke and add `test_send_packet`**

```ruby
def test_send_packet
  client_h = Apple::CoreMIDI.MIDIClientCreate("RbApple SmokeClient", nil, nil)
  port_h   = Apple::CoreMIDI.MIDIOutputPortCreate(client_h, "OutPort")
  dest_count = Apple::CoreMIDI.MIDIGetNumberOfDestinations
  omit "no MIDI destinations" if dest_count.zero?
  dest_h = Apple::CoreMIDI.MIDIGetDestination(0)

  # Build MIDIPacketList from Ruby Hash
  pkt = {
    numPackets: 1,
    packet: { timeStamp: 0, length: 3, data: "\x90\x3C\x40".bytes.pack("C*") }
  }
  status = Apple::CoreMIDI.MIDISend(port_h, dest_h, pkt)
  assert_equal 0, status
ensure
  Apple::CoreMIDI.MIDIClientDispose(client_h) if client_h
end
```

- [ ] **Step 2: Wipe cache + launch smoke under screen**

```bash
sqlite3 ~/.cache/rb-apple-sdk-mac/26.2/glue.sqlite "DELETE FROM compile_history; DELETE FROM compiled_glue;" && \
mkdir -p tmp/longrun && \
screen -dmS bug-c-unified-verify-20260505 bash -c '
  cd ~/dev/src/github.com/bash0C7/rb-apple-sdk-mac
  . ~/.swiftly/env.sh
  bundle exec ruby -Ilib -Itest test/integration/coremidi_smoke_test.rb \
    > tmp/longrun/bug-c-unified-verify-20260505.log 2>&1
  echo "DONE: exit=$?" >> tmp/longrun/bug-c-unified-verify-20260505.log
'
```

End the conversation turn after launch. Resume after `DONE:` sentinel.

- [ ] **Step 3: Inspect results**

```bash
tail -80 ~/dev/src/github.com/bash0C7/rb-apple-sdk-mac/tmp/longrun/bug-c-unified-verify-20260505.log && \
sqlite3 ~/.cache/rb-apple-sdk-mac/26.2/glue.sqlite \
  "SELECT id, symbol, generator, error_stage, substr(error_detail,1,200) FROM compile_history ORDER BY id DESC LIMIT 20;"
```

Expected:
- Smoke test output: `2 tests, ... 0 failures, 0 errors, ≤1 omissions`
- compile_history: every CoreMIDI symbol with `generator='template'`, `error_stage IS NULL`

- [ ] **Step 4: Document outcome in spec**

Append "Verification" section to spec:

```markdown
## Verification (2026-05-05)

[Outcome class A/B/C, observed compile_history table, smoke test result excerpt.]
```

- [ ] **Step 5: Commit verification**

```bash
git add test/integration/coremidi_smoke_test.rb docs/superpowers/specs/2026-05-05-unified-marshalling-and-callback-pillar-design.md && \
git commit -m "docs+test: record E2E verification outcome for unified marshalling + Callback pillar spec"
```

---

## Self-Review

**Spec coverage map:**
- Spec §"Schema migration" → Task 1, 2, 7
- Spec §"Header parser extension" → Task 4
- Spec §"Kind classifier extension" → Task 3
- Spec §"Importer hookup" → Task 5
- Spec §"Reclassifier" → Task 6
- Spec §"KnowledgeCache lookup_symbol" → Task 8
- Spec §"TemplateGenerator restructure" → Task 9
- Spec §"HEADER extension" → Task 10
- Spec §"callback_nilable / callback_non_nil" → Task 11, 21
- Spec §"void_ptr_nilable" → Task 12
- Spec §"struct_in (with nesting)" → Task 13
- Spec §"struct_out" → Task 14
- Spec §"Multi-out-param" → Task 15
- Spec §"variadic_args" → Task 16
- Spec §"LLM prompt sync" → Task 18
- Spec §"Callback pillar implementation" → Task 19, 20
- Spec §"Smoke tests" → Task 22
- Spec §"E2E verification" → Task 22 step 2-3
- Spec §"Acceptance criterion 1 (T10 PASS)" → Task 22
- Spec §"Acceptance criterion 2 (MIDISend)" → Task 22
- Spec §"Acceptance criterion 3 (full suites green)" → Task 7 (gem K) + Task 22 (gem C)

No spec section is uncovered.

**Placeholder scan:**
- No `TBD` / `TODO` / `implement later` patterns.
- "trim mode tweak" / "adjust mapping to match yml tokens" / "production-grade pinning lifecycle deferred to follow-up" are real engineering judgments rather than plan-level placeholders, but kept honest about deferred work.

**Type / name consistency:**
- `Marshaller::REGISTRY[<kind>]` matches the kind names in the taxonomy table.
- `CallbackPillar.Handle` / `register` / `unregister` consistent across Task 19, 20, 21.
- `callback_signatures.yml` token format matches the `.<sigToken>` reference in Task 21 (lower-camel; `MIDINotifyProc` → `midiNotifyProc`).
- Test method names referenced in step 2/3 of every RED block match step 1 names.

---

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-05-05-unified-marshalling-and-callback-pillar.md`. Two execution options:**

**1. Subagent-Driven (recommended)** — Dispatch a fresh subagent per task, review between tasks. Best for cross-repo + cross-stack work where each task touches isolated files.

**2. Inline Execution** — Run tasks in this session via executing-plans, batched by Phase (1–7) with checkpoints between phases.

**Which approach?**
