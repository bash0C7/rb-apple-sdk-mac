# Deterministic Runtime Phase 1: Knowledge Base Completeness — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Knowledge Base schema を拡張し、 clang ObjC importer + Swift overlay importer を broader framework + 全 high-priority metadata 取り込みに拡張する。 KnowledgeCache consumer side で新 column を expose。

**Architecture:** SCHEMA_VERSION 7 → 9 bump で migrate! が既存 cache を invalidate。 store.rb の insert_symbol に新 keyword 引数を追加し、 両 importer から populate。 KnowledgeCache の lookup_symbol / lookup_klass_method 戻り Hash に新 key を追加して、 後続 Phase (emitter / runtime refactor) が consume できる state にする。

**Tech Stack:** Ruby 3.x (RUBY_BOX=1 で実行)、 SQLite3 (rb_apple_sdk_knowledge sub-gem)、 test-unit、 Bundler、 clang AST (ObjC importer)、 swiftinterface text parse (Swift overlay importer)

**Spec reference:** `docs/superpowers/specs/2026-05-14-deterministic-runtime-mcp-helper-design.md` の Section 2 + Section 3。

**Branch:** `feature/eliminate-claude-swift-trial-and-error` 上で続行 (前 session の commit 群と同 branch)。

---

## File Structure

### Modify

- `knowledge/lib/rb_apple_sdk_knowledge/store.rb`
  - `SCHEMA_VERSION` を 7 → 9 bump (前 session 改修は importer decl Hash と KnowledgeCache 戻り Hash の拡張のみで schema は無変更、 本 phase で初めて schema に新 column を物理追加)
  - `SCHEMA_SQL` に 9 個の追加 column (`is_throws` / `is_async` / `is_failable` / `is_settable` / `return_ownership` / `throws_error_type` / `callback_signature_json` / `enum_cases_json` / `unsupported_pattern`)
  - `insert_symbol` keyword 引数追加 + SQL 引数 placeholder 拡張
- `knowledge/lib/rb_apple_sdk_knowledge/importer/swift_overlay.rb`
  - 前 session commit d0dc563 で `is_throws` / `is_async` / `is_failable` 等の effect modifier は decl Hash 内 boolean に capture 済 (ただし schema には未 lift)、 本 phase で `insert_symbol` 経由 schema column に persist + 残 metadata 追加
- `knowledge/lib/rb_apple_sdk_knowledge/importer/clang_objc.rb` (or 同等の clang AST 経由 importer ファイル名、 Task 3 冒頭で `Explore` で実位置確認)
  - _Nullable / cf_returns_retained / typed block signature / inline detection / function-macro detection
- `knowledge/lib/rb_apple_sdk_knowledge/importer/*` (swift_overlay 以外の Swift 関連 importer、 同 Task 3 で実位置確認)
- `lib/apple_sdk_mac/knowledge_cache.rb`
  - `lookup_symbol` / `lookup_klass_method` の SELECT に新 column 追加
  - 戻り Hash に新 key 追加 (Boolean は Integer → Ruby Boolean 化)
- `knowledge/Rakefile` (existence verify、 必要時 `apple:knowledge:rebuild_async` task の env 確認)

### Create

- `knowledge/test/store_schema_phase1_test.rb`
  - SCHEMA_VERSION 値 + 追加 column 存在検証
  - insert_symbol に新 keyword で値渡し → SELECT で値が戻ること
- `knowledge/test/importer/swift_overlay_phase1_test.rb`
  - 既存 `swift_overlay_test.rb` と独立、 新 metadata capture を fixture 経由で検証
- `knowledge/test/importer/clang_objc_phase1_test.rb`
  - _Nullable / cf_returns_retained / inline / function-macro capture を fixture (`tmp/sdk_fixture/` 配下の限定 header) 経由で検証

### Test

- `knowledge/test/store_schema_phase1_test.rb` (Task 1, 2)
- `knowledge/test/importer/clang_objc_phase1_test.rb` (Task 3-7)
- `knowledge/test/importer/swift_overlay_phase1_test.rb` (Task 8-14)
- `test/knowledge_cache_test.rb` (Task 16, 17、 既存 test に追加)

---

## TDD policy

- 各 task は RED test (Step 1) → fail 確認 (Step 2) → minimal GREEN (Step 3) → pass 確認 (Step 4) → commit (Step 5) を必ず履行
- 全 suite green じゃないと next task に進まへん
- `bundle exec rake test` (主 gem) と `cd knowledge && bundle exec rake test` (sub-gem) の両方 green を維持
- commit 単位は 1 logical change、 Conventional Commits (feat / fix / refactor / test / docs / chore)、 Co-Authored-By: Claude Opus 4.7

---

## Test command reference

主 gem:
```bash
bundle exec rake test                                    # 全テスト
bundle exec rake test TEST=test/knowledge_cache_test.rb  # 単一ファイル
bundle exec rake test TESTOPTS="-n test_specific_name"   # 単一 test method
```

knowledge sub-gem:
```bash
cd knowledge && bundle exec rake test
cd knowledge && bundle exec rake test TEST=test/store_schema_phase1_test.rb
```

KB rebuild (Task 18):
```bash
bundle exec rake apple:knowledge:rebuild_async   # screen -dmS で背景化
tail -f tmp/longrun/apple-knowledge-rebuild-*.log
grep "^DONE:" tmp/longrun/apple-knowledge-rebuild-*.log
```

---

## Task 1: SCHEMA_VERSION bump + schema_sql に新 column 9 個追加

**Files:**
- Modify: `knowledge/lib/rb_apple_sdk_knowledge/store.rb:1-78` (SCHEMA_VERSION 行 + SCHEMA_SQL の `symbols` テーブル定義)
- Create: `knowledge/test/store_schema_phase1_test.rb`

- [ ] **Step 1: Write the failing test**

`knowledge/test/store_schema_phase1_test.rb` を新規作成:

```ruby
# frozen_string_literal: true
require "test_helper"
require "tmpdir"
require "rb_apple_sdk_knowledge/store"

class TestStoreSchemaPhase1 < Test::Unit::TestCase
  def test_schema_version_is_at_least_9
    assert_operator AppleSDKKnowledge::Store::SCHEMA_VERSION, :>=, 9,
      "Phase 1 で SCHEMA_VERSION 9 に bump 必須"
  end

  def test_symbols_table_has_new_phase1_columns
    Dir.mktmpdir do |dir|
      db_path = File.join(dir, "k.sqlite")
      store = AppleSDKKnowledge::Store.open(db_path)
      cols = store.db.execute("PRAGMA table_info(symbols)").map { |r| r[1] }
      %w[
        is_throws is_async is_failable is_settable
        return_ownership throws_error_type callback_signature_json
        enum_cases_json unsupported_pattern
      ].each do |col|
        assert_includes cols, col, "symbols table に #{col} column が必要"
      end
      store.close
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd knowledge && bundle exec rake test TEST=test/store_schema_phase1_test.rb
```

Expected: 2 tests fail。 SCHEMA_VERSION = 7 < 9 / 新 column 全部不在。

- [ ] **Step 3: Write minimal implementation**

`knowledge/lib/rb_apple_sdk_knowledge/store.rb`:

Line 9 を `SCHEMA_VERSION = 9` に変更。

Line 29-46 の `CREATE TABLE IF NOT EXISTS symbols` 内に、 既存 `swift_imported_name TEXT` の行の前に以下を追加:

```sql
        is_throws            INTEGER NOT NULL DEFAULT 0,
        is_async             INTEGER NOT NULL DEFAULT 0,
        is_failable          INTEGER NOT NULL DEFAULT 0,
        is_settable          INTEGER NOT NULL DEFAULT 0,
        return_ownership     TEXT,
        throws_error_type    TEXT,
        callback_signature_json TEXT,
        enum_cases_json      TEXT,
        unsupported_pattern  TEXT,
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd knowledge && bundle exec rake test TEST=test/store_schema_phase1_test.rb
```

Expected: 2 tests PASS。

`cd knowledge && bundle exec rake test` で全 sub-gem テスト green 維持確認 (既存 store_test 等が schema 変更で壊れてへんこと)。 main gem 側も `bundle exec rake test` 通すこと (KnowledgeCache 等の consumer は schema 変更単独では破綻せん想定、 もし壊れたら Task 16 まで待たず即修正)。

- [ ] **Step 5: Commit**

```bash
git add knowledge/lib/rb_apple_sdk_knowledge/store.rb knowledge/test/store_schema_phase1_test.rb
git commit -m "$(cat <<'EOF'
feat(knowledge): bump SCHEMA_VERSION to 9 and add phase 1 metadata columns

Add 9 new symbols-table columns for deterministic-runtime phase 1:
is_throws / is_async / is_failable / is_settable / return_ownership /
throws_error_type / callback_signature_json / enum_cases_json /
unsupported_pattern. Existing caches auto-invalidate via schema_meta
version mismatch on next migrate.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: store.insert_symbol に新 keyword 引数追加

**Files:**
- Modify: `knowledge/lib/rb_apple_sdk_knowledge/store.rb:88-127` (insert_symbol method)
- Test: `knowledge/test/store_schema_phase1_test.rb` (Task 1 で作成、 追加 test を append)

- [ ] **Step 1: Write the failing test**

`knowledge/test/store_schema_phase1_test.rb` の末尾に追加:

```ruby
  def test_insert_symbol_accepts_phase1_keywords_and_round_trips
    Dir.mktmpdir do |dir|
      db_path = File.join(dir, "k.sqlite")
      store = AppleSDKKnowledge::Store.open(db_path)
      fid = store.insert_framework(name: "Test", swift_module: "Test")
      sid = store.insert_symbol(
        framework_id: fid, name: "doStuff", kind: "function", abi: "c",
        content_hash: "h-dostuff",
        is_throws: 1, is_async: 1, is_failable: 0, is_settable: 1,
        return_ownership: "retained",
        throws_error_type: "NSError",
        callback_signature_json: '{"params":[{"type":"URL"}],"return_type":"Void"}',
        enum_cases_json: '["create","createAndPrepend"]',
        unsupported_pattern: nil,
      )
      assert_kind_of Integer, sid

      row = store.db.execute(<<~SQL, [sid]).first
        SELECT is_throws, is_async, is_failable, is_settable,
               return_ownership, throws_error_type, callback_signature_json,
               enum_cases_json, unsupported_pattern
        FROM symbols WHERE id = ?
      SQL
      assert_equal 1, row[0]
      assert_equal 1, row[1]
      assert_equal 0, row[2]
      assert_equal 1, row[3]
      assert_equal "retained", row[4]
      assert_equal "NSError", row[5]
      assert_equal '{"params":[{"type":"URL"}],"return_type":"Void"}', row[6]
      assert_equal '["create","createAndPrepend"]', row[7]
      assert_nil row[8]
      store.close
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd knowledge && bundle exec rake test TEST=test/store_schema_phase1_test.rb TESTOPTS="-n test_insert_symbol_accepts_phase1_keywords_and_round_trips"
```

Expected: FAIL with `ArgumentError: unknown keyword: :is_throws` 等。

- [ ] **Step 3: Write minimal implementation**

`knowledge/lib/rb_apple_sdk_knowledge/store.rb` line 88-127 の `insert_symbol` を変更:

```ruby
    def insert_symbol(framework_id:, name:, kind:, abi:, content_hash:,
                       parent_id: nil, signature: nil, documentation: nil,
                       return_type: nil, parameters_json: nil, availability: nil,
                       deprecated: 0, requires_main_thread: 0, fields_json: nil,
                       swift_imported_name: nil,
                       is_throws: 0, is_async: 0, is_failable: 0, is_settable: 0,
                       return_ownership: nil, throws_error_type: nil,
                       callback_signature_json: nil, enum_cases_json: nil,
                       unsupported_pattern: nil)
      @db.execute(
        <<~SQL,
          INSERT INTO symbols
          (framework_id, name, parent_id, kind, signature, abi, documentation,
           return_type, parameters_json, availability, deprecated,
           requires_main_thread, content_hash, fields_json, swift_imported_name,
           is_throws, is_async, is_failable, is_settable,
           return_ownership, throws_error_type, callback_signature_json,
           enum_cases_json, unsupported_pattern)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(content_hash) DO UPDATE SET
            framework_id    = excluded.framework_id,
            name            = excluded.name,
            parent_id       = excluded.parent_id,
            kind            = excluded.kind,
            signature       = excluded.signature,
            abi             = excluded.abi,
            documentation   = excluded.documentation,
            return_type     = excluded.return_type,
            parameters_json = excluded.parameters_json,
            availability    = excluded.availability,
            deprecated      = excluded.deprecated,
            requires_main_thread = excluded.requires_main_thread,
            fields_json     = COALESCE(excluded.fields_json, symbols.fields_json),
            swift_imported_name = COALESCE(excluded.swift_imported_name, symbols.swift_imported_name),
            is_throws       = excluded.is_throws,
            is_async        = excluded.is_async,
            is_failable     = excluded.is_failable,
            is_settable     = excluded.is_settable,
            return_ownership = COALESCE(excluded.return_ownership, symbols.return_ownership),
            throws_error_type = COALESCE(excluded.throws_error_type, symbols.throws_error_type),
            callback_signature_json = COALESCE(excluded.callback_signature_json, symbols.callback_signature_json),
            enum_cases_json = COALESCE(excluded.enum_cases_json, symbols.enum_cases_json),
            unsupported_pattern = COALESCE(excluded.unsupported_pattern, symbols.unsupported_pattern)
        SQL
        [framework_id, name, parent_id, kind, signature, abi, documentation,
         return_type, parameters_json, availability, deprecated,
         requires_main_thread, content_hash, fields_json, swift_imported_name,
         is_throws, is_async, is_failable, is_settable,
         return_ownership, throws_error_type, callback_signature_json,
         enum_cases_json, unsupported_pattern]
      )
      row = @db.execute("SELECT id FROM symbols WHERE content_hash = ?", [content_hash]).first
      row && row.first
    end
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd knowledge && bundle exec rake test TEST=test/store_schema_phase1_test.rb
cd knowledge && bundle exec rake test
bundle exec rake test
```

Expected: 全 PASS。 既存 store / importer test が backward compatible で壊れてへんこと。

- [ ] **Step 5: Commit**

```bash
git add knowledge/lib/rb_apple_sdk_knowledge/store.rb knowledge/test/store_schema_phase1_test.rb
git commit -m "$(cat <<'EOF'
feat(knowledge): extend insert_symbol with phase 1 metadata keywords

is_throws / is_async / is_failable / is_settable (Integer flags),
return_ownership / throws_error_type / callback_signature_json /
enum_cases_json / unsupported_pattern (TEXT, nullable). UPSERT
ON CONFLICT preserves prior values via COALESCE for the TEXT
columns; the Integer flags overwrite on re-import.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: clang importer ファイル位置の確認 + _Nullable capture (TDD)

**目的:** ObjC header の `_Nullable` / `_Nonnull` attribute を per-parameter / per-return basis で `parameters_json` の element に nullable boolean として埋め込む。 import 後 KB record の parameters_json [i] が `{name:, type:, kind:, nullable: true|false}` 形を持つ。

**Files (Task 3 冒頭で確認、 想定位置):**
- Modify: `knowledge/lib/rb_apple_sdk_knowledge/importer/*.rb` のうち、 clang AST 経由で ObjC header を ingest しとるファイル
- Create: `knowledge/test/importer/clang_objc_phase1_test.rb`

- [ ] **Step 1: clang importer ファイル位置確認**

```bash
ls knowledge/lib/rb_apple_sdk_knowledge/importer/
grep -l "clang\|FullComment\|cursor\|libclang" knowledge/lib/rb_apple_sdk_knowledge/importer/*.rb 2>/dev/null
```

clang AST 経由 importer ファイル名を確認、 以後本 task では仮に `clang_objc.rb` 名で書く。 実ファイル名が違ったら、 Step 3 以降の path 文字列を実位置に置換すること (`grep "_Nullable\|Nullable\|nullability"` でも検索可能)。

- [ ] **Step 2: Write the failing test**

`knowledge/test/importer/clang_objc_phase1_test.rb` 新規:

```ruby
# frozen_string_literal: true
require "test_helper"
require "tmpdir"
require "json"
require "rb_apple_sdk_knowledge/store"
# require_relative の path は Step 1 で確認した実ファイル位置で書き直すこと
require "rb_apple_sdk_knowledge/importer/clang_objc"

class TestClangObjcImporterPhase1 < Test::Unit::TestCase
  # ObjC `_Nullable` / `_Nonnull` がparameters_jsonの各elementにnullableとして
  # 持たれていることを fixture header 経由で検証。
  def test_nullable_attribute_captured_per_parameter
    Dir.mktmpdir do |dir|
      header = File.join(dir, "TestFW.h")
      File.write(header, <<~HEADER)
        @interface TestObj : NSObject
        - (void)doStuff:(NSString * _Nullable)maybe with:(NSString * _Nonnull)required;
        @end
      HEADER
      db_path = File.join(dir, "k.sqlite")
      store = AppleSDKKnowledge::Store.open(db_path)
      # Step 3 で importer の actual entry-point method を確認して呼び出すこと
      AppleSDKKnowledge::Importer::ClangObjc.import_file(
        store: store, framework: "TestFW", file: header
      )
      sym = store.db.execute(
        "SELECT parameters_json FROM symbols WHERE name = ?", ["doStuff:with:"]
      ).first
      assert_not_nil sym, "doStuff:with: が import されてへんで"
      params = JSON.parse(sym[0])
      assert_equal 2, params.size
      assert_equal true,  params[0]["nullable"], "maybe は _Nullable やから true"
      assert_equal false, params[1]["nullable"], "required は _Nonnull やから false"
      store.close
    end
  end
end
```

注: importer の entry-point method 名 (`import_file`) は Task 3 Step 1 で確認した実 API に合わせて修正すること。 もし API が `import_framework` だけで file 単位 entry が無い場合は fixture を framework 体裁で渡す or importer に新しい file-level helper を切ること (この場合 helper 切る作業も本 task に含める)。

- [ ] **Step 3: Run test to verify it fails**

```bash
cd knowledge && bundle exec rake test TEST=test/importer/clang_objc_phase1_test.rb
```

Expected: FAIL。 `_Nullable` 未 capture → params[0]["nullable"] が nil または key 無し。

- [ ] **Step 4: Write minimal implementation**

clang importer の parameter ingest 経路 (Task 3 Step 1 で位置確認した file) で、 各 parameter cursor から nullability を抽出して parameters_json element に `nullable` key を追加:

```ruby
# clang_objc.rb の parameter ingest 箇所 (概要、 actual code は Step 1 確認後に
# implementer が specific line に当てはめる)
def parameter_to_hash(cursor)
  type = cursor.type
  nullability =
    case type.respond_to?(:nullability) && type.nullability
    when :nullable then true
    when :nonnull  then false
    else nil  # unspecified
    end
  {
    name: cursor.spelling,
    type: type.spelling,
    kind: infer_kind(type),
    nullable: nullability,
  }
end
```

libclang Ruby binding (`ffi-clang` 等、 既存依存) の Type#nullability API がそのまま使えるか importer code base で確認。 もし binding に nullability accessor が無い場合は `cursor.type.spelling` に含まれる `_Nullable` / `_Nonnull` keyword を文字列 match で fallback (例: `type.spelling =~ /_Nullable\b/`)。

- [ ] **Step 5: Run test to verify it passes**

```bash
cd knowledge && bundle exec rake test TEST=test/importer/clang_objc_phase1_test.rb
cd knowledge && bundle exec rake test
```

Expected: 全 PASS。

- [ ] **Step 6: Commit**

```bash
git add knowledge/lib/rb_apple_sdk_knowledge/importer/clang_objc.rb knowledge/test/importer/clang_objc_phase1_test.rb
git commit -m "$(cat <<'EOF'
feat(knowledge/importer): capture _Nullable / _Nonnull per parameter

ObjC header の Nullability annotation を parameters_json の per-element
nullable boolean に lift。 unspecified は nil (Ruby) / NULL (JSON)。
emitter は本 column を Qnil ガード判定に使う (phase 2 で消化)。

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: clang importer cf_returns_retained capture (TDD)

**目的:** `__attribute__((cf_returns_retained))` / `NS_RETURNS_RETAINED` を return_ownership に lift。

**Files:**
- Modify: `knowledge/lib/rb_apple_sdk_knowledge/importer/clang_objc.rb`
- Test: `knowledge/test/importer/clang_objc_phase1_test.rb` (Task 3 で作成済)

- [ ] **Step 1: Write the failing test**

`knowledge/test/importer/clang_objc_phase1_test.rb` の末尾に追加:

```ruby
  def test_cf_returns_retained_captured_to_return_ownership
    Dir.mktmpdir do |dir|
      header = File.join(dir, "TestFW.h")
      File.write(header, <<~HEADER)
        CFStringRef MyCopyName(void) __attribute__((cf_returns_retained));
        CFStringRef MyGetName(void);
      HEADER
      db_path = File.join(dir, "k.sqlite")
      store = AppleSDKKnowledge::Store.open(db_path)
      AppleSDKKnowledge::Importer::ClangObjc.import_file(
        store: store, framework: "TestFW", file: header
      )
      row1 = store.db.execute("SELECT return_ownership FROM symbols WHERE name = ?", ["MyCopyName"]).first
      row2 = store.db.execute("SELECT return_ownership FROM symbols WHERE name = ?", ["MyGetName"]).first
      assert_equal "retained", row1[0],
        "cf_returns_retained 付きは return_ownership = 'retained'"
      assert_nil row2[0],
        "annotation 無しは unspecified (NULL)、 emitter 側 heuristic にゆずる"
      store.close
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd knowledge && bundle exec rake test TEST=test/importer/clang_objc_phase1_test.rb TESTOPTS="-n test_cf_returns_retained_captured_to_return_ownership"
```

Expected: FAIL。 return_ownership column populate されてへん。

- [ ] **Step 3: Write minimal implementation**

clang importer の function-decl ingest 経路で、 attribute child cursors を traverse して `cf_returns_retained` / `ns_returns_retained` / `__attribute__((ns_returns_retained))` を検出、 `return_ownership = "retained"` を `insert_symbol` に渡す:

```ruby
# function decl の処理ループ内
def function_attributes(cursor)
  retained = false
  cursor.visit_children do |child, _|
    if child.kind == :cursor_unexposed_attr
      # libclang は cf_returns_retained を unexposed として扱う (バージョン依存)
      # 名前は cursor.spelling では取得できんため、 src range の token から判定
      tokens = child.translation_unit.tokenize(child.extent).map(&:spelling)
      retained ||= tokens.any? { |t| t == "cf_returns_retained" || t == "ns_returns_retained" }
    end
    :recurse
  end
  retained ? { return_ownership: "retained" } : {}
end
```

`function_attributes(cursor)` の返値を `insert_symbol` に `**function_attributes(cursor)` で splat。

- [ ] **Step 4: Run test to verify it passes**

```bash
cd knowledge && bundle exec rake test TEST=test/importer/clang_objc_phase1_test.rb
cd knowledge && bundle exec rake test
```

Expected: 全 PASS。

- [ ] **Step 5: Commit**

```bash
git add knowledge/lib/rb_apple_sdk_knowledge/importer/clang_objc.rb knowledge/test/importer/clang_objc_phase1_test.rb
git commit -m "$(cat <<'EOF'
feat(knowledge/importer): capture cf_returns_retained as return_ownership

`__attribute__((cf_returns_retained))` / `NS_RETURNS_RETAINED` を
return_ownership = 'retained' に lift。 emitter (phase 2) で CF
Create-Rule auto-arc 判定の naming heuristic を本 column 由来に
置き換える土台。

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: clang importer typed block signature capture (TDD)

**目的:** ObjC method parameter の `void (^)(NSError * _Nullable)` block 型を `callback_signature_json` (text JSON) として symbol-level に persist。

**Files:**
- Modify: `knowledge/lib/rb_apple_sdk_knowledge/importer/clang_objc.rb`
- Test: `knowledge/test/importer/clang_objc_phase1_test.rb`

- [ ] **Step 1: Write the failing test**

```ruby
  def test_typed_block_parameter_lifts_callback_signature_json
    Dir.mktmpdir do |dir|
      header = File.join(dir, "TestFW.h")
      File.write(header, <<~HEADER)
        @interface TestObj : NSObject
        - (void)doAsync:(void (^)(NSError * _Nullable))handler;
        @end
      HEADER
      db_path = File.join(dir, "k.sqlite")
      store = AppleSDKKnowledge::Store.open(db_path)
      AppleSDKKnowledge::Importer::ClangObjc.import_file(
        store: store, framework: "TestFW", file: header
      )
      row = store.db.execute(
        "SELECT callback_signature_json FROM symbols WHERE name = ?", ["doAsync:"]
      ).first
      assert_not_nil row, "doAsync: が import されてへん"
      json = row[0]
      assert_not_nil json, "callback_signature_json が NULL"
      parsed = JSON.parse(json)
      assert_equal "Void", parsed["return_type"]
      assert_equal 1, parsed["params"].size
      assert_equal "NSError",  parsed["params"][0]["type"]
      assert_equal true,       parsed["params"][0]["nullable"]
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd knowledge && bundle exec rake test TEST=test/importer/clang_objc_phase1_test.rb TESTOPTS="-n test_typed_block_parameter_lifts_callback_signature_json"
```

Expected: FAIL。

- [ ] **Step 3: Write minimal implementation**

clang importer の method parameter visit ループで、 type kind が `:type_block_pointer` の場合に pointee 関数型から argument types + result type を抽出して JSON 化:

```ruby
def extract_block_signature(param_cursor)
  type = param_cursor.type
  return nil unless type.kind == :type_block_pointer
  pointee = type.pointee
  args = pointee.argument_types.map.with_index do |arg_t, i|
    {
      type: simple_type_name(arg_t),
      nullable: extract_nullability(arg_t),
    }
  end
  {
    params: args,
    return_type: simple_type_name(pointee.result_type),
  }
end

def simple_type_name(type)
  # NSError * _Nullable → "NSError"、 void → "Void"、 NSURL * → "NSURL"
  spelling = type.spelling
  return "Void" if spelling == "void"
  spelling.sub(/\s*\*.*$/, "").sub(/^const\s+/, "").strip
end
```

method symbol 単位で 1 block parameter のみ想定 (Apple SDK 慣例)、 複数 block parameter は最初の 1 個のみ lift、 残りは parameters_json に普通の void* として記載 (phase 2 で expansion 検討)。

`insert_symbol` 呼び出し時に `callback_signature_json: JSON.dump(extract_block_signature(first_block_cursor))` を渡す。

- [ ] **Step 4: Run test to verify it passes**

```bash
cd knowledge && bundle exec rake test TEST=test/importer/clang_objc_phase1_test.rb
cd knowledge && bundle exec rake test
```

Expected: 全 PASS。

- [ ] **Step 5: Commit**

```bash
git add knowledge/lib/rb_apple_sdk_knowledge/importer/clang_objc.rb knowledge/test/importer/clang_objc_phase1_test.rb
git commit -m "$(cat <<'EOF'
feat(knowledge/importer): lift typed ObjC block signatures to callback_signature_json

ObjC method の block parameter (`void (^)(NSError * _Nullable)` 等) を
JSON 構造化 ({params:[{type,nullable}], return_type:}) して symbol 単位
に persist。 phase 2 emitter で runtime_callback_pillar_register_* 経路
の auto-route 判定 hash 元として使う。

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: clang importer inline-only function detection (TDD)

**目的:** header の `static inline` 関数を import するが `unsupported_pattern = "inline_only"` marker を付与する。 emitter (phase 2) は call 時 raise する。

**Files:**
- Modify: `knowledge/lib/rb_apple_sdk_knowledge/importer/clang_objc.rb`
- Test: `knowledge/test/importer/clang_objc_phase1_test.rb`

- [ ] **Step 1: Write the failing test**

```ruby
  def test_static_inline_function_is_marked_unsupported_inline_only
    Dir.mktmpdir do |dir|
      header = File.join(dir, "TestFW.h")
      File.write(header, <<~HEADER)
        static inline int MyFastDouble(int x) { return x * 2; }
        extern int MyRegularFunc(int x);
      HEADER
      db_path = File.join(dir, "k.sqlite")
      store = AppleSDKKnowledge::Store.open(db_path)
      AppleSDKKnowledge::Importer::ClangObjc.import_file(
        store: store, framework: "TestFW", file: header
      )
      row1 = store.db.execute("SELECT unsupported_pattern FROM symbols WHERE name = ?", ["MyFastDouble"]).first
      row2 = store.db.execute("SELECT unsupported_pattern FROM symbols WHERE name = ?", ["MyRegularFunc"]).first
      assert_equal "inline_only", row1[0],
        "static inline は dylib symbol 無し、 marker 必須"
      assert_nil row2[0],
        "通常 extern は marker 無し"
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd knowledge && bundle exec rake test TEST=test/importer/clang_objc_phase1_test.rb TESTOPTS="-n test_static_inline_function_is_marked_unsupported_inline_only"
```

Expected: FAIL。

- [ ] **Step 3: Write minimal implementation**

function decl の visit 内で `cursor.storage_class == :sc_static` AND `cursor.has_inline_attr?` (or pragma 経由 inline keyword 検出) のとき `unsupported_pattern: "inline_only"` を `insert_symbol` に渡す:

```ruby
def function_pattern_marker(cursor)
  inline = cursor.respond_to?(:linkage) && cursor.linkage == :external
  # libclang FFI binding 経由で inline attr を取れへん場合、 cursor.extent の
  # source range を read して `static inline` keyword を文字列検出するfallback
  return "inline_only" if static_inline?(cursor)
  nil
end

def static_inline?(cursor)
  range_text = source_text(cursor.extent)
  range_text =~ /\bstatic\b.*?\binline\b|\binline\b.*?\bstatic\b/m ? true : false
end
```

`insert_symbol` 呼び出しに `unsupported_pattern: function_pattern_marker(cursor)` を渡す。

- [ ] **Step 4: Run test to verify it passes**

```bash
cd knowledge && bundle exec rake test TEST=test/importer/clang_objc_phase1_test.rb
cd knowledge && bundle exec rake test
```

Expected: 全 PASS。

- [ ] **Step 5: Commit**

```bash
git add knowledge/lib/rb_apple_sdk_knowledge/importer/clang_objc.rb knowledge/test/importer/clang_objc_phase1_test.rb
git commit -m "$(cat <<'EOF'
feat(knowledge/importer): mark static inline functions with unsupported_pattern

dylib symbol を持たへん header inline 関数を import するが
unsupported_pattern = 'inline_only' を付与。 phase 2 emitter で
call 時に rich diagnostic raise の判定材料。

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: clang importer function-like macro detection (TDD)

**目的:** `#define CGRectMake(x,y,w,h) ((CGRect){{x,y},{w,h}})` のような function-like macro を symbol として import + `unsupported_pattern = "function_macro"` marker。

**Files:**
- Modify: `knowledge/lib/rb_apple_sdk_knowledge/importer/clang_objc.rb`
- Test: `knowledge/test/importer/clang_objc_phase1_test.rb`

- [ ] **Step 1: Write the failing test**

```ruby
  def test_function_like_macro_marked_unsupported_function_macro
    Dir.mktmpdir do |dir|
      header = File.join(dir, "TestFW.h")
      File.write(header, <<~HEADER)
        #define MakeWidget(name) ((Widget *)widgetCreate(name))
        #define MY_CONSTANT 42
      HEADER
      db_path = File.join(dir, "k.sqlite")
      store = AppleSDKKnowledge::Store.open(db_path)
      AppleSDKKnowledge::Importer::ClangObjc.import_file(
        store: store, framework: "TestFW", file: header
      )
      row1 = store.db.execute("SELECT unsupported_pattern FROM symbols WHERE name = ?", ["MakeWidget"]).first
      row2 = store.db.execute("SELECT name FROM symbols WHERE name = ?", ["MY_CONSTANT"]).first
      assert_equal "function_macro", row1[0],
        "MakeWidget は function-like macro、 marker 必須"
      # MY_CONSTANT は value macro、 既存挙動 (constant kind として import) に従う、 marker 無し
      assert_not_nil row2, "MY_CONSTANT も import される (既存挙動)"
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd knowledge && bundle exec rake test TEST=test/importer/clang_objc_phase1_test.rb TESTOPTS="-n test_function_like_macro_marked_unsupported_function_macro"
```

Expected: FAIL。

- [ ] **Step 3: Write minimal implementation**

macro_definition cursor visit ループで `cursor.macro_function_like?` true の場合 `unsupported_pattern: "function_macro"` 付与 + kind を `function_macro` 等の専用 enum に。 既存 macro ingest path が constant 扱いになってる場合は kind を変えへんと既存 importer / consumer に影響しない様慎重 (kind は既存値維持、 unsupported_pattern marker のみ追加):

```ruby
def macro_pattern_marker(cursor)
  return "function_macro" if cursor.respond_to?(:macro_function_like?) && cursor.macro_function_like?
  nil
end
```

`insert_symbol(... unsupported_pattern: macro_pattern_marker(cursor))`。

- [ ] **Step 4: Run test to verify it passes**

```bash
cd knowledge && bundle exec rake test TEST=test/importer/clang_objc_phase1_test.rb
cd knowledge && bundle exec rake test
```

Expected: 全 PASS。

- [ ] **Step 5: Commit**

```bash
git add knowledge/lib/rb_apple_sdk_knowledge/importer/clang_objc.rb knowledge/test/importer/clang_objc_phase1_test.rb
git commit -m "$(cat <<'EOF'
feat(knowledge/importer): mark function-like C macros with unsupported_pattern

preprocessor 展開のみで dylib symbol を持たへん function-like macro
(e.g. CGRectMake) を import し unsupported_pattern = 'function_macro'
marker を付与。 value-style macro (`#define MY_CONSTANT 42`) は対象外、
既存 constant ingest を維持。

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: swift_overlay importer effect flags の DB persist (TDD)

**目的:** 前 commit d0dc563 で decl Hash に capture 済の `throws / async / failable` を schema の `is_throws / is_async / is_failable` column に persist する path を `upsert_decl` に追加。

**Files:**
- Modify: `knowledge/lib/rb_apple_sdk_knowledge/importer/swift_overlay.rb` (前 session で d0dc563 改修済 file)
- Create: `knowledge/test/importer/swift_overlay_phase1_test.rb`

- [ ] **Step 1: Write the failing test**

`knowledge/test/importer/swift_overlay_phase1_test.rb` 新規:

```ruby
# frozen_string_literal: true
require "test_helper"
require "tmpdir"
require "rb_apple_sdk_knowledge/store"
require "rb_apple_sdk_knowledge/importer/swift_overlay"

class TestSwiftOverlayImporterPhase1 < Test::Unit::TestCase
  def test_throws_init_persists_is_throws_and_is_failable
    Dir.mktmpdir do |dir|
      interface = File.join(dir, "TestFW.swiftinterface")
      File.write(interface, <<~SWIFT)
        // swift-interface-format-version: 1.0
        import Foundation
        public class TestKlass {
          public init(forReading url: URL) throws
          public init?(string: String)
          public func parse(_ data: Data) async throws -> URL
        }
      SWIFT
      db_path = File.join(dir, "k.sqlite")
      store = AppleSDKKnowledge::Store.open(db_path)
      AppleSDKKnowledge::Importer::SwiftOverlay.import_file(
        store: store, framework: "TestFW", file: interface
      )
      # init(forReading:): throws=1, async=0, failable=0
      r1 = store.db.execute(<<~SQL, ["init(forReading:)", "TestKlass"]).first
        SELECT s.is_throws, s.is_async, s.is_failable
        FROM symbols s JOIN symbols p ON s.parent_id = p.id
        WHERE s.name = ? AND p.name = ?
      SQL
      assert_equal [1, 0, 0], r1, "init(forReading:) throws"

      r2 = store.db.execute(<<~SQL, ["init(string:)", "TestKlass"]).first
        SELECT s.is_throws, s.is_async, s.is_failable
        FROM symbols s JOIN symbols p ON s.parent_id = p.id
        WHERE s.name = ? AND p.name = ?
      SQL
      assert_equal [0, 0, 1], r2, "init?(string:) failable"

      r3 = store.db.execute(<<~SQL, ["parse(_:)", "TestKlass"]).first
        SELECT s.is_throws, s.is_async, s.is_failable
        FROM symbols s JOIN symbols p ON s.parent_id = p.id
        WHERE s.name = ? AND p.name = ?
      SQL
      assert_equal [1, 1, 0], r3, "async throws"
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd knowledge && bundle exec rake test TEST=test/importer/swift_overlay_phase1_test.rb
```

Expected: FAIL。 effect flags が 0 のまま (column は存在するが populate 経路無い)。

- [ ] **Step 3: Write minimal implementation**

`knowledge/lib/rb_apple_sdk_knowledge/importer/swift_overlay.rb` の `upsert_decl` (前 session で改修済) に effect flags を `insert_symbol` に渡す path を追加:

```ruby
# upsert_decl 内の insert_symbol 呼び出し箇所 (前 commit d0dc563 で改修済)
store.insert_symbol(
  framework_id: framework_id,
  parent_id: parent_id,
  name: decl[:name],
  kind: decl[:kind],
  abi: "swift",
  content_hash: hash,
  signature: decl[:signature],
  return_type: decl[:return_type],   # bb060c9 で追加済
  is_throws:    decl[:throws]    ? 1 : 0,  # 本 task で追加
  is_async:     decl[:async]     ? 1 : 0,  # 本 task で追加
  is_failable:  decl[:failable]  ? 1 : 0,  # 本 task で追加
)
```

`decl[:throws]` 等 boolean key は前 commit d0dc563 で既に parse_decl_line 戻り Hash に含まれてる。 もし key 名が違ったら (`:is_throws` 等) parse_decl_line 側に合わせる。

- [ ] **Step 4: Run test to verify it passes**

```bash
cd knowledge && bundle exec rake test TEST=test/importer/swift_overlay_phase1_test.rb
cd knowledge && bundle exec rake test
```

Expected: 全 PASS (前 session の swift_overlay_test も green 維持)。

- [ ] **Step 5: Commit**

```bash
git add knowledge/lib/rb_apple_sdk_knowledge/importer/swift_overlay.rb knowledge/test/importer/swift_overlay_phase1_test.rb
git commit -m "$(cat <<'EOF'
feat(knowledge/importer): persist swift_overlay throws/async/failable to schema

前 commit d0dc563 で decl Hash に capture 済の effect modifier を
schema column (is_throws / is_async / is_failable) に lift。
consumer (KnowledgeCache / phase 2 emitter) が KB record の Boolean
column を直接読める state にする。

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: swift_overlay importer label (external + internal name) capture (TDD)

**目的:** Swift method の 2 種 label を parameters_json の per-element に lift。 `init(forReading url: URL)` → element に `external_label: "forReading", internal_name: "url"`。

**Files:**
- Modify: `knowledge/lib/rb_apple_sdk_knowledge/importer/swift_overlay.rb`
- Test: `knowledge/test/importer/swift_overlay_phase1_test.rb`

- [ ] **Step 1: Write the failing test**

`swift_overlay_phase1_test.rb` 末尾追加:

```ruby
  def test_parameter_external_and_internal_labels_captured
    Dir.mktmpdir do |dir|
      interface = File.join(dir, "TestFW.swiftinterface")
      File.write(interface, <<~SWIFT)
        // swift-interface-format-version: 1.0
        import Foundation
        public class TestKlass {
          public init(forReading url: URL)
          public init(_ raw: String)
          public func render(into target: Image, with options: Options)
        }
      SWIFT
      db_path = File.join(dir, "k.sqlite")
      store = AppleSDKKnowledge::Store.open(db_path)
      AppleSDKKnowledge::Importer::SwiftOverlay.import_file(
        store: store, framework: "TestFW", file: interface
      )
      # init(forReading url:): external_label = "forReading", internal_name = "url"
      params1 = JSON.parse(store.db.execute(<<~SQL, ["init(forReading:)", "TestKlass"]).first[0])
        SELECT s.parameters_json FROM symbols s JOIN symbols p ON s.parent_id = p.id
        WHERE s.name = ? AND p.name = ?
      SQL
      assert_equal "forReading", params1[0]["external_label"]
      assert_equal "url",        params1[0]["internal_name"]

      # init(_ raw:): external_label = nil (anonymous _), internal_name = "raw"
      params2 = JSON.parse(store.db.execute(<<~SQL, ["init(_:)", "TestKlass"]).first[0])
        SELECT s.parameters_json FROM symbols s JOIN symbols p ON s.parent_id = p.id
        WHERE s.name = ? AND p.name = ?
      SQL
      assert_nil      params2[0]["external_label"]
      assert_equal "raw", params2[0]["internal_name"]

      # render(into:with:): 2 引数とも 2 label
      params3 = JSON.parse(store.db.execute(<<~SQL, ["render(into:with:)", "TestKlass"]).first[0])
        SELECT s.parameters_json FROM symbols s JOIN symbols p ON s.parent_id = p.id
        WHERE s.name = ? AND p.name = ?
      SQL
      assert_equal "into",   params3[0]["external_label"]
      assert_equal "target", params3[0]["internal_name"]
      assert_equal "with",    params3[1]["external_label"]
      assert_equal "options", params3[1]["internal_name"]
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd knowledge && bundle exec rake test TEST=test/importer/swift_overlay_phase1_test.rb TESTOPTS="-n test_parameter_external_and_internal_labels_captured"
```

Expected: FAIL。 parameters_json element に external_label / internal_name key 無し。

- [ ] **Step 3: Write minimal implementation**

`swift_overlay.rb` の parameter-parsing logic を拡張。 Swift method signature の paren 内を split したあと、 各 element を以下 pattern で 2 label に分解:

- `_ raw: String` → external_label = nil, internal_name = "raw"
- `forReading url: URL` → external_label = "forReading", internal_name = "url"
- `url: URL` → external_label = "url", internal_name = "url" (Swift convention)

```ruby
PARAM_RE = /
  \A
  (?:(?<external>_|[a-zA-Z_]\w*)\s+)?  # optional external label or _
  (?<internal>[a-zA-Z_]\w*)            # internal name
  \s*:\s*
  (?<type>.+?)
  \z
/x

def parse_parameter(text)
  m = PARAM_RE.match(text.strip)
  return nil unless m
  external = m[:external]
  internal = m[:internal]
  type     = m[:type].strip
  # Swift convention: `name: Type` (no explicit external) は external=internal
  external_label =
    if external.nil?
      internal
    elsif external == "_"
      nil
    else
      external
    end
  {
    name: internal,                # 既存 key 維持 (consumer 互換)
    external_label: external_label,
    internal_name: internal,
    type: type,
    kind: infer_kind_from_swift_type(type),
    nullable: type.end_with?("?"),
  }
end
```

upsert_decl で parameters_json 生成時に `parse_parameter` 経由で element 化、 JSON.dump で persist。

- [ ] **Step 4: Run test to verify it passes**

```bash
cd knowledge && bundle exec rake test TEST=test/importer/swift_overlay_phase1_test.rb
cd knowledge && bundle exec rake test
```

Expected: 全 PASS。 既存 swift_overlay_test の parameters_json 形式の test がもし「name + kind のみ」 を期待してる場合、 新 key 増えても backward compatible (key 増えるだけ)、 既存 assert は壊れへん想定。 壊れる test があれば本 task で additive に修正。

- [ ] **Step 5: Commit**

```bash
git add knowledge/lib/rb_apple_sdk_knowledge/importer/swift_overlay.rb knowledge/test/importer/swift_overlay_phase1_test.rb
git commit -m "$(cat <<'EOF'
feat(knowledge/importer): capture swift external_label + internal_name per parameter

Swift method signature の 2 label 系統 (`forReading url: URL`) を
parameters_json element に external_label / internal_name として lift。
`_ raw:` の anonymous は external_label = nil、 `url: URL` の single
は Swift convention で external = internal = "url"。
phase 2 emitter で signature 文字列 parse を本 KB column に置換する土台。

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: swift_overlay default value literal capture (TDD)

**目的:** `encoding: String.Encoding = .utf8` の literal default value を parameters_json element に `default_value` key として lift。 複雑 expression (関数呼び出し等) は NULL のまま。

**Files:**
- Modify: `knowledge/lib/rb_apple_sdk_knowledge/importer/swift_overlay.rb`
- Test: `knowledge/test/importer/swift_overlay_phase1_test.rb`

- [ ] **Step 1: Write the failing test**

```ruby
  def test_default_value_literal_captured
    Dir.mktmpdir do |dir|
      interface = File.join(dir, "TestFW.swiftinterface")
      File.write(interface, <<~SWIFT)
        // swift-interface-format-version: 1.0
        import Foundation
        public class TestKlass {
          public init(value: Int = 42, name: String = "default", encoding: String.Encoding = .utf8)
          public init(callback: () -> Void = { })  // closure default は capture せず NULL
        }
      SWIFT
      db_path = File.join(dir, "k.sqlite")
      store = AppleSDKKnowledge::Store.open(db_path)
      AppleSDKKnowledge::Importer::SwiftOverlay.import_file(
        store: store, framework: "TestFW", file: interface
      )
      params1 = JSON.parse(store.db.execute(<<~SQL, ["init(value:name:encoding:)", "TestKlass"]).first[0])
        SELECT s.parameters_json FROM symbols s JOIN symbols p ON s.parent_id = p.id
        WHERE s.name = ? AND p.name = ?
      SQL
      assert_equal "42",           params1[0]["default_value"]
      assert_equal "\"default\"",  params1[1]["default_value"]
      assert_equal ".utf8",        params1[2]["default_value"]

      params2 = JSON.parse(store.db.execute(<<~SQL, ["init(callback:)", "TestKlass"]).first[0])
        SELECT s.parameters_json FROM symbols s JOIN symbols p ON s.parent_id = p.id
        WHERE s.name = ? AND p.name = ?
      SQL
      assert_nil params2[0]["default_value"],
        "closure default は literal じゃないから NULL"
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd knowledge && bundle exec rake test TEST=test/importer/swift_overlay_phase1_test.rb TESTOPTS="-n test_default_value_literal_captured"
```

Expected: FAIL。 default_value key 無し。

- [ ] **Step 3: Write minimal implementation**

`parse_parameter` を拡張:

```ruby
PARAM_RE = /
  \A
  (?:(?<external>_|[a-zA-Z_]\w*)\s+)?
  (?<internal>[a-zA-Z_]\w*)
  \s*:\s*
  (?<type>.+?)
  (?:\s*=\s*(?<default>.+))?      # optional default
  \z
/x

LITERAL_DEFAULT_RE = /\A(?:
  -?\d+(?:\.\d+)?  # numeric literal
  | "[^"]*"        # string literal
  | \.\w+          # dot-prefixed enum case (.utf8, .red)
  | true|false|nil
)\z/x

def extract_default_value(raw)
  return nil if raw.nil?
  stripped = raw.strip
  LITERAL_DEFAULT_RE.match?(stripped) ? stripped : nil
end
```

`parse_parameter` の戻り Hash に `default_value: extract_default_value(m[:default])` を追加。

- [ ] **Step 4: Run test to verify it passes**

```bash
cd knowledge && bundle exec rake test TEST=test/importer/swift_overlay_phase1_test.rb
cd knowledge && bundle exec rake test
```

Expected: 全 PASS。

- [ ] **Step 5: Commit**

```bash
git add knowledge/lib/rb_apple_sdk_knowledge/importer/swift_overlay.rb knowledge/test/importer/swift_overlay_phase1_test.rb
git commit -m "$(cat <<'EOF'
feat(knowledge/importer): capture literal default values per parameter

Numeric / string / dot-prefixed enum case / bool / nil literal を
parameters_json element の default_value に lift。 closure / function
call / 複雑 expression は NULL のまま (phase 2 emitter は default 値
ありなら glue で arg N 省略可能、 NULL なら user に explicit 渡し必須)。

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 11: swift_overlay Optional 階層 nullable 正確 capture (TDD)

**目的:** Swift `URL?` / `URL??` を parameters_json element に nullable = true で正確 capture (前 task 9 で end_with?("?") の crude 検出済、 ここで階層対応に refine)。

**Files:**
- Modify: `knowledge/lib/rb_apple_sdk_knowledge/importer/swift_overlay.rb`
- Test: `knowledge/test/importer/swift_overlay_phase1_test.rb`

- [ ] **Step 1: Write the failing test**

```ruby
  def test_optional_layer_captured_as_nullable
    Dir.mktmpdir do |dir|
      interface = File.join(dir, "TestFW.swiftinterface")
      File.write(interface, <<~SWIFT)
        // swift-interface-format-version: 1.0
        import Foundation
        public class TestKlass {
          public func one(_ x: URL?)
          public func two(_ x: URL??)
          public func three(_ x: Array<URL?>)  // 内部 ? は外形ではないため nullable=false
          public func four(_ x: URL!)          // ImplicitlyUnwrapped も nullable
        }
      SWIFT
      db_path = File.join(dir, "k.sqlite")
      store = AppleSDKKnowledge::Store.open(db_path)
      AppleSDKKnowledge::Importer::SwiftOverlay.import_file(
        store: store, framework: "TestFW", file: interface
      )

      one = JSON.parse(store.db.execute(<<~SQL, ["one(_:)", "TestKlass"]).first[0])
        SELECT s.parameters_json FROM symbols s JOIN symbols p ON s.parent_id = p.id
        WHERE s.name = ? AND p.name = ?
      SQL
      assert_equal true, one[0]["nullable"]

      two = JSON.parse(store.db.execute(<<~SQL, ["two(_:)", "TestKlass"]).first[0])
        SELECT s.parameters_json FROM symbols s JOIN symbols p ON s.parent_id = p.id
        WHERE s.name = ? AND p.name = ?
      SQL
      assert_equal true, two[0]["nullable"]

      three = JSON.parse(store.db.execute(<<~SQL, ["three(_:)", "TestKlass"]).first[0])
        SELECT s.parameters_json FROM symbols s JOIN symbols p ON s.parent_id = p.id
        WHERE s.name = ? AND p.name = ?
      SQL
      assert_equal false, three[0]["nullable"],
        "Array<URL?> は外形が non-optional"

      four = JSON.parse(store.db.execute(<<~SQL, ["four(_:)", "TestKlass"]).first[0])
        SELECT s.parameters_json FROM symbols s JOIN symbols p ON s.parent_id = p.id
        WHERE s.name = ? AND p.name = ?
      SQL
      assert_equal true, four[0]["nullable"], "URL! も nullable"
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd knowledge && bundle exec rake test TEST=test/importer/swift_overlay_phase1_test.rb TESTOPTS="-n test_optional_layer_captured_as_nullable"
```

Expected: 内 task 9 の `end_with?("?")` は `URL!` を false にしてる + `Array<URL?>` も誤って true に → 1-2 件 fail 想定。

- [ ] **Step 3: Write minimal implementation**

`parse_parameter` の nullable 判定を refine:

```ruby
def nullable_outer?(type)
  s = type.to_s.strip
  # 外形末尾 ? または ! (1 個以上)、 ただし >? 等の generic 内末尾は除外
  # トリック: balance check で paren / bracket / angle が全部 close した直後の ? か !
  depth = 0
  s.each_char.with_index do |c, i|
    case c
    when '(', '[', '<' then depth += 1
    when ')', ']', '>' then depth -= 1
    end
  end
  return false unless depth == 0
  s.end_with?("?") || s.end_with?("!")
end
```

`parse_parameter` 内の `nullable:` を `nullable_outer?(type)` に置換。

- [ ] **Step 4: Run test to verify it passes**

```bash
cd knowledge && bundle exec rake test TEST=test/importer/swift_overlay_phase1_test.rb
cd knowledge && bundle exec rake test
```

Expected: 全 PASS。

- [ ] **Step 5: Commit**

```bash
git add knowledge/lib/rb_apple_sdk_knowledge/importer/swift_overlay.rb knowledge/test/importer/swift_overlay_phase1_test.rb
git commit -m "$(cat <<'EOF'
feat(knowledge/importer): refine swift Optional / IUO nullable detection

外形 Optional (`URL?` / `URL??`) と Implicitly-Unwrapped Optional
(`URL!`) を nullable = true、 内側 Optional (`Array<URL?>`) は外形が
non-optional なので false に正確判定。 paren/bracket/angle の depth
balance で外形を識別。

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 12: swift_overlay enum cases capture (TDD)

**目的:** Swift `enum WriteMode { case create, .createAndPrepend }` の case 列挙を parent enum symbol の `enum_cases_json` column に persist。

**Files:**
- Modify: `knowledge/lib/rb_apple_sdk_knowledge/importer/swift_overlay.rb`
- Test: `knowledge/test/importer/swift_overlay_phase1_test.rb`

- [ ] **Step 1: Write the failing test**

```ruby
  def test_enum_cases_captured_to_enum_cases_json
    Dir.mktmpdir do |dir|
      interface = File.join(dir, "TestFW.swiftinterface")
      File.write(interface, <<~SWIFT)
        // swift-interface-format-version: 1.0
        public enum WriteMode {
          case create
          case createAndPrepend
          case truncate
        }
      SWIFT
      db_path = File.join(dir, "k.sqlite")
      store = AppleSDKKnowledge::Store.open(db_path)
      AppleSDKKnowledge::Importer::SwiftOverlay.import_file(
        store: store, framework: "TestFW", file: interface
      )
      row = store.db.execute(
        "SELECT enum_cases_json FROM symbols WHERE name = ?", ["WriteMode"]
      ).first
      assert_not_nil row, "WriteMode が import されてへん"
      cases = JSON.parse(row[0])
      assert_equal %w[create createAndPrepend truncate], cases
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd knowledge && bundle exec rake test TEST=test/importer/swift_overlay_phase1_test.rb TESTOPTS="-n test_enum_cases_captured_to_enum_cases_json"
```

Expected: FAIL。

- [ ] **Step 3: Write minimal implementation**

`swift_overlay.rb` の enum 検出 path に case 列挙の regex parse 追加:

```ruby
DECL_ENUM_RE = /(?:open|public)\s+enum\s+(\w+)(?:\s*:\s*[\w<>,\s]+)?\s*\{/.freeze
CASE_RE      = /^\s*case\s+([a-zA-Z_]\w*(?:\s*,\s*[a-zA-Z_]\w*)*)/

def parse_enum_block(text, name)
  start_idx = text.index(/(?:open|public)\s+enum\s+#{Regexp.escape(name)}\b/)
  return [] unless start_idx
  # match brace block で end_idx 検出 (簡易: brace count で balance)
  body = ...  # enum 本体抽出
  cases = []
  body.scan(CASE_RE) do |m|
    m[0].split(",").map(&:strip).each { |c| cases << c }
  end
  cases
end
```

import_file の各 enum symbol 処理で:
```ruby
store.insert_symbol(
  ..., name: enum_name, kind: "enum",
  enum_cases_json: JSON.dump(parse_enum_block(file_text, enum_name)),
)
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd knowledge && bundle exec rake test TEST=test/importer/swift_overlay_phase1_test.rb
cd knowledge && bundle exec rake test
```

Expected: 全 PASS。

- [ ] **Step 5: Commit**

```bash
git add knowledge/lib/rb_apple_sdk_knowledge/importer/swift_overlay.rb knowledge/test/importer/swift_overlay_phase1_test.rb
git commit -m "$(cat <<'EOF'
feat(knowledge/importer): capture Swift enum cases to enum_cases_json

`public enum X { case a, case b }` の case 列挙を JSON array で
enum_cases_json column に persist。 phase 2 namespace_builder で
Apple::<F>::<Enum>::<Case> 定数 install の source。

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 13: swift_overlay is_settable flag capture (TDD)

**目的:** `var x: Int { get set }` を is_settable = 1、 `var y: Int { get }` を 0 に区別。

**Files:**
- Modify: `knowledge/lib/rb_apple_sdk_knowledge/importer/swift_overlay.rb`
- Test: `knowledge/test/importer/swift_overlay_phase1_test.rb`

- [ ] **Step 1: Write the failing test**

```ruby
  def test_property_is_settable_distinguished
    Dir.mktmpdir do |dir|
      interface = File.join(dir, "TestFW.swiftinterface")
      File.write(interface, <<~SWIFT)
        // swift-interface-format-version: 1.0
        public class TestKlass {
          public var writable: Int { get set }
          public var readonly: Int { get }
        }
      SWIFT
      db_path = File.join(dir, "k.sqlite")
      store = AppleSDKKnowledge::Store.open(db_path)
      AppleSDKKnowledge::Importer::SwiftOverlay.import_file(
        store: store, framework: "TestFW", file: interface
      )
      r1 = store.db.execute(<<~SQL, ["writable", "TestKlass"]).first
        SELECT s.is_settable FROM symbols s JOIN symbols p ON s.parent_id = p.id
        WHERE s.name = ? AND p.name = ?
      SQL
      r2 = store.db.execute(<<~SQL, ["readonly", "TestKlass"]).first
        SELECT s.is_settable FROM symbols s JOIN symbols p ON s.parent_id = p.id
        WHERE s.name = ? AND p.name = ?
      SQL
      assert_equal 1, r1[0]
      assert_equal 0, r2[0]
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd knowledge && bundle exec rake test TEST=test/importer/swift_overlay_phase1_test.rb TESTOPTS="-n test_property_is_settable_distinguished"
```

Expected: FAIL。

- [ ] **Step 3: Write minimal implementation**

`swift_overlay.rb` の var-decl parse 経路 (DECL_VAR_RE 等) で `{ get set }` を `is_settable = 1`、 `{ get }` だけは 0 に判定:

```ruby
DECL_VAR_RE = /(?:open|public)\s+var\s+(\w+)\s*:\s*([^{\n]+?)\s*\{\s*(get(?:\s+set)?)\s*\}/.freeze

def parse_var_decl(line)
  m = DECL_VAR_RE.match(line)
  return nil unless m
  {
    name: m[1],
    type: m[2].strip,
    is_settable: m[3].include?("set") ? 1 : 0,
  }
end
```

upsert_decl で `insert_symbol(..., is_settable: decl[:is_settable] || 0)` を渡す。

- [ ] **Step 4: Run test to verify it passes**

```bash
cd knowledge && bundle exec rake test TEST=test/importer/swift_overlay_phase1_test.rb
cd knowledge && bundle exec rake test
```

Expected: 全 PASS。

- [ ] **Step 5: Commit**

```bash
git add knowledge/lib/rb_apple_sdk_knowledge/importer/swift_overlay.rb knowledge/test/importer/swift_overlay_phase1_test.rb
git commit -m "$(cat <<'EOF'
feat(knowledge/importer): capture swift property readwrite as is_settable

`var x: Int { get set }` を is_settable = 1、 `{ get }` のみは 0。
phase 2 emitter で setter glue (`obj.prop = val`) auto-emit の trigger。

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 14: swift_overlay macro / result_builder usage marker (TDD)

**目的:** `@Observable class Foo {}` / `@ViewBuilder var body: View` 等の syntactic transformation を `unsupported_pattern` marker に lift。

**Files:**
- Modify: `knowledge/lib/rb_apple_sdk_knowledge/importer/swift_overlay.rb`
- Test: `knowledge/test/importer/swift_overlay_phase1_test.rb`

- [ ] **Step 1: Write the failing test**

```ruby
  def test_swift_macro_attribute_marked_unsupported
    Dir.mktmpdir do |dir|
      interface = File.join(dir, "TestFW.swiftinterface")
      File.write(interface, <<~SWIFT)
        // swift-interface-format-version: 1.0
        @Observable public class WatchedThing {
          public var value: Int { get set }
        }
        public class PlainThing {
          @ViewBuilder public var body: AnyView { get }
        }
      SWIFT
      db_path = File.join(dir, "k.sqlite")
      store = AppleSDKKnowledge::Store.open(db_path)
      AppleSDKKnowledge::Importer::SwiftOverlay.import_file(
        store: store, framework: "TestFW", file: interface
      )
      r1 = store.db.execute("SELECT unsupported_pattern FROM symbols WHERE name = ?", ["WatchedThing"]).first
      assert_equal "swift_macro", r1[0],
        "@Observable class は macro marker"

      r2 = store.db.execute(<<~SQL, ["body", "PlainThing"]).first
        SELECT s.unsupported_pattern FROM symbols s JOIN symbols p ON s.parent_id = p.id
        WHERE s.name = ? AND p.name = ?
      SQL
      assert_equal "result_builder", r2[0],
        "@ViewBuilder property は result_builder marker"
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd knowledge && bundle exec rake test TEST=test/importer/swift_overlay_phase1_test.rb TESTOPTS="-n test_swift_macro_attribute_marked_unsupported"
```

Expected: FAIL。

- [ ] **Step 3: Write minimal implementation**

`swift_overlay.rb` の line / block 単位 attribute scan を追加。 既知 macro / result_builder attribute の固定 list と match:

```ruby
SWIFT_MACRO_ATTRS = %w[
  @Observable @MainActor.preconcurrency @attached @freestanding
].freeze

SWIFT_RESULT_BUILDER_ATTRS = %w[
  @ViewBuilder @SceneBuilder @CommandsBuilder @ToolbarContentBuilder
  @RegexComponentBuilder
].freeze

def detect_unsupported(line, preceding_attrs)
  return "swift_macro"    if preceding_attrs.any? { |a| SWIFT_MACRO_ATTRS.include?(a) }
  return "result_builder" if preceding_attrs.any? { |a| SWIFT_RESULT_BUILDER_ATTRS.include?(a) }
  nil
end
```

decl scanner で直前の `@<Attr>` 行を蓄積 → decl 本体に到達したら detect_unsupported に渡す。 一致時 `insert_symbol(..., unsupported_pattern: ...)` に lift。

- [ ] **Step 4: Run test to verify it passes**

```bash
cd knowledge && bundle exec rake test TEST=test/importer/swift_overlay_phase1_test.rb
cd knowledge && bundle exec rake test
```

Expected: 全 PASS。

- [ ] **Step 5: Commit**

```bash
git add knowledge/lib/rb_apple_sdk_knowledge/importer/swift_overlay.rb knowledge/test/importer/swift_overlay_phase1_test.rb
git commit -m "$(cat <<'EOF'
feat(knowledge/importer): mark Swift macros / result builders as unsupported_pattern

`@Observable` / `@ViewBuilder` 等の compile-time syntactic transformation
を unsupported_pattern marker (`swift_macro` / `result_builder`) に lift。
phase 2 emitter / dispatcher が call 時に rich diagnostic raise する trigger。

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 15: swift_overlay importer の broader framework coverage 確認 (TDD)

**目的:** importer の current entry point が Foundation / AppKit / SwiftUI / Metal / SceneKit / Vision 等の swiftinterface も等しく ingest できる state にあるか fixture-based test で確認、 不足あれば修正。

**Files:**
- Modify (必要時): `knowledge/lib/rb_apple_sdk_knowledge/importer/swift_overlay.rb` / `knowledge/lib/rb_apple_sdk_knowledge/importer/discovery.rb` (or 同等の framework 列挙ファイル)
- Test: `knowledge/test/importer/swift_overlay_phase1_test.rb`

- [ ] **Step 1: Write the failing test**

```ruby
  # Framework discovery / file enumeration の lib 経路で、 macOS SDK 内の
  # swift overlay framework 一覧が拾えてるかを smoke test。 importer entry
  # API は `framework_swiftinterface_paths(sdk_root)` を想定。
  def test_framework_discovery_includes_main_overlays
    sdk_root = `xcrun --show-sdk-path 2>/dev/null`.strip
    omit "macOS SDK not found (xcrun missing)" if sdk_root.empty?
    omit "macOS SDK path does not exist" unless File.directory?(sdk_root)

    paths = AppleSDKKnowledge::Importer::SwiftOverlay.framework_swiftinterface_paths(sdk_root)
    framework_names = paths.map { |p| File.basename(p, ".swiftinterface") }.uniq

    %w[Foundation AppKit SwiftUI].each do |fw|
      assert framework_names.any? { |n| n.start_with?(fw) },
        "expected overlay #{fw} swiftinterface to be discovered"
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd knowledge && bundle exec rake test TEST=test/importer/swift_overlay_phase1_test.rb TESTOPTS="-n test_framework_discovery_includes_main_overlays"
```

Expected: 既存 importer が AVFAudio 等限定なら FAIL、 すでに broad path discovery やってるなら最初から PASS。 後者の場合は Step 3 をスキップ → そのまま commit。

- [ ] **Step 3: Write minimal implementation (Step 2 で FAIL した場合のみ)**

discovery 経路を SDK 内の `System/Library/Frameworks/*/Modules/*.swiftmodule/*.swiftinterface` (or `*/Modules/*/<arch>.swiftinterface`) glob で広く拾うように拡張:

```ruby
def self.framework_swiftinterface_paths(sdk_root)
  Dir.glob([
    File.join(sdk_root, "System/Library/Frameworks/*.framework/Modules/*.swiftmodule/*.swiftinterface"),
    File.join(sdk_root, "System/Library/Frameworks/*.framework/Modules/*.swiftmodule/*/*.swiftinterface"),
  ]).uniq
end
```

`apple:knowledge:rebuild` task の framework 列挙経路も同 helper を経由するよう統一 (現状 ハードコード list があれば外す、 または extend する)。

- [ ] **Step 4: Run test to verify it passes**

```bash
cd knowledge && bundle exec rake test TEST=test/importer/swift_overlay_phase1_test.rb
cd knowledge && bundle exec rake test
```

Expected: 全 PASS。

- [ ] **Step 5: Commit (Step 3 で変更があった場合のみ; 既存挙動で pass したら test 追加だけ commit)**

```bash
git add knowledge/lib/rb_apple_sdk_knowledge/importer/swift_overlay.rb knowledge/test/importer/swift_overlay_phase1_test.rb
git commit -m "$(cat <<'EOF'
test(knowledge/importer): verify broader framework swiftinterface discovery

Foundation / AppKit / SwiftUI 等 主要 Swift overlay framework が
importer の discovery path で拾えることを smoke test 化。 拡張が
必要な場合は同 commit で SDK frameworks glob を統一。

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 16: KnowledgeCache.lookup_symbol / lookup_klass_method に新 column expose (TDD)

**目的:** lookup_symbol / lookup_klass_method の戻り Hash に 9 個の新 column を key として追加。 Integer flags は Boolean (true/false) に変換、 TEXT は nil-or-string、 nullable な json は文字列のまま (consumer 側で parse 責務)。

**Files:**
- Modify: `lib/apple_sdk_mac/knowledge_cache.rb:30-94` (lookup_symbol 内 SELECT + Hash 生成、 lookup_klass_method 同)
- Test: `test/knowledge_cache_test.rb` (既存 file の末尾に追加)

- [ ] **Step 1: Write the failing test**

`test/knowledge_cache_test.rb` 末尾に追加:

```ruby
  # Phase 1: lookup_symbol が新 column 9 個を expose する。
  def test_lookup_symbol_surfaces_phase1_metadata
    Dir.mktmpdir do |dir|
      db_path = File.join(dir, "k.sqlite")
      store = AppleSDKKnowledge::Store.open(db_path)
      fid = store.insert_framework(name: "Acme", swift_module: "Acme")
      store.insert_symbol(
        framework_id: fid, name: "doThrow", kind: "function", abi: "c",
        content_hash: "h-throw",
        is_throws: 1, is_async: 1, is_failable: 0, is_settable: 0,
        return_ownership: "retained",
        throws_error_type: "NSError",
        callback_signature_json: '{"params":[],"return_type":"Void"}',
        enum_cases_json: nil,
        unsupported_pattern: nil,
      )
      cache = AppleSDKMac::KnowledgeCache.new(store)
      sym = cache.lookup_symbol(framework: "Acme", symbol: "doThrow")
      assert_not_nil sym
      assert_equal true,  sym[:is_throws]
      assert_equal true,  sym[:is_async]
      assert_equal false, sym[:is_failable]
      assert_equal false, sym[:is_settable]
      assert_equal "retained", sym[:return_ownership]
      assert_equal "NSError",  sym[:throws_error_type]
      assert_equal '{"params":[],"return_type":"Void"}', sym[:callback_signature_json]
      assert_nil sym[:enum_cases_json]
      assert_nil sym[:unsupported_pattern]
      cache.close
    end
  end

  # parent_id 経由 lookup でも同様。
  def test_lookup_klass_method_surfaces_phase1_metadata
    Dir.mktmpdir do |dir|
      db_path = File.join(dir, "k.sqlite")
      store = AppleSDKKnowledge::Store.open(db_path)
      fid = store.insert_framework(name: "AVFAudio", swift_module: "AVFAudio")
      pid = store.insert_symbol(
        framework_id: fid, name: "AVAudioEngine",
        kind: "class", abi: "swift", content_hash: "h-ae",
      )
      store.insert_symbol(
        framework_id: fid, parent_id: pid, name: "start",
        kind: "instance_method", abi: "swift", content_hash: "h-start",
        is_throws: 1,
      )
      cache = AppleSDKMac::KnowledgeCache.new(store)
      rec = cache.lookup_klass_method(framework: "AVFAudio",
                                       klass: "AVAudioEngine",
                                       method: "start")
      assert_not_nil rec
      assert_equal true, rec[:is_throws]
      assert_equal false, rec[:is_async]
      cache.close
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
bundle exec rake test TEST=test/knowledge_cache_test.rb TESTOPTS="-n test_lookup_symbol_surfaces_phase1_metadata"
bundle exec rake test TEST=test/knowledge_cache_test.rb TESTOPTS="-n test_lookup_klass_method_surfaces_phase1_metadata"
```

Expected: FAIL。 戻り Hash に新 key が無い。

- [ ] **Step 3: Write minimal implementation**

`lib/apple_sdk_mac/knowledge_cache.rb` の `lookup_symbol`:

Line 33-41 の SQL SELECT を以下に変更:

```ruby
      row = @db.execute(<<~SQL, [framework, symbol]).first
        SELECT s.id, s.name, s.kind, s.signature, s.abi, s.documentation,
               s.parameters_json, s.requires_main_thread, s.content_hash,
               s.fields_json, s.return_type,
               s.is_throws, s.is_async, s.is_failable, s.is_settable,
               s.return_ownership, s.throws_error_type,
               s.callback_signature_json, s.enum_cases_json,
               s.unsupported_pattern
        FROM symbols s
        JOIN frameworks f ON s.framework_id = f.id
        WHERE f.name = ? AND s.name = ?
        LIMIT 1
      SQL
```

Line 42-48 の Hash 生成を:

```ruby
      return nil unless row
      {
        id: row[0], name: row[1], kind: row[2], signature: row[3],
        abi: row[4], documentation: row[5], parameters_json: row[6],
        requires_main_thread: row[7] == 1, content_hash: row[8],
        fields_json: row[9], return_type: row[10],
        is_throws:    row[11] == 1,
        is_async:     row[12] == 1,
        is_failable:  row[13] == 1,
        is_settable:  row[14] == 1,
        return_ownership: row[15],
        throws_error_type: row[16],
        callback_signature_json: row[17],
        enum_cases_json: row[18],
        unsupported_pattern: row[19],
      }
```

`lookup_klass_method` (line 76-94) も同 column を SELECT 追加 + Hash key 追加:

```ruby
    def lookup_klass_method(framework:, klass:, method:)
      row = @db.execute(<<~SQL, [framework, klass, method]).first
        SELECT s.id, s.name, s.kind, s.signature, s.abi, s.documentation,
               s.parameters_json, s.requires_main_thread, s.content_hash,
               s.fields_json, s.return_type,
               s.is_throws, s.is_async, s.is_failable, s.is_settable,
               s.return_ownership, s.throws_error_type,
               s.callback_signature_json, s.enum_cases_json,
               s.unsupported_pattern
        FROM symbols s
        JOIN symbols p     ON s.parent_id = p.id
        JOIN frameworks f  ON s.framework_id = f.id
        WHERE f.name = ? AND p.name = ? AND s.name = ?
        LIMIT 1
      SQL
      return nil unless row
      {
        id: row[0], name: row[1], kind: row[2], signature: row[3],
        abi: row[4], documentation: row[5], parameters_json: row[6],
        requires_main_thread: row[7] == 1, content_hash: row[8],
        fields_json: row[9], return_type: row[10],
        is_throws:    row[11] == 1,
        is_async:     row[12] == 1,
        is_failable:  row[13] == 1,
        is_settable:  row[14] == 1,
        return_ownership: row[15],
        throws_error_type: row[16],
        callback_signature_json: row[17],
        enum_cases_json: row[18],
        unsupported_pattern: row[19],
      }
    end
```

- [ ] **Step 4: Run test to verify it passes**

```bash
bundle exec rake test TEST=test/knowledge_cache_test.rb
bundle exec rake test
```

Expected: 全 PASS。 既存 lookup_symbol / lookup_klass_method consumer (emitter / dispatcher etc) は新 key 増えても backward compatible (Hash key 増えるだけ)、 既存 test green 維持。

- [ ] **Step 5: Commit**

```bash
git add lib/apple_sdk_mac/knowledge_cache.rb test/knowledge_cache_test.rb
git commit -m "$(cat <<'EOF'
feat(knowledge_cache): surface phase 1 metadata in lookup_symbol / lookup_klass_method

Knowledge Base schema 9 で persist 済の 9 column を lookup の戻り Hash に
expose: is_throws/is_async/is_failable/is_settable (Boolean 化)、
return_ownership/throws_error_type/callback_signature_json/
enum_cases_json/unsupported_pattern (string-or-nil)。 phase 2 emitter /
dispatcher が KB record から signature 文字列 parse 無しで dispatch できる
土台。

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 17: KB rebuild smoke run + stats 確認 (manual gate)

**目的:** SCHEMA_VERSION 9 schema で全 framework rebuild が走り、 importer 拡張が production-scale で破綻せえへんことを確認。 Phase 1 完了 gate。

**Files:** (実機 file 変更無し、 KB rebuild + stats 確認のみ)

- [ ] **Step 1: 旧 cache を scoped rake task で clear**

まず該当 rake task の存在確認:
```bash
bundle exec rake -T | grep -E "cache:|knowledge:" | sort
```

`apple:cache:clear_knowledge` (or 同等の scoped task) が listed されてれば実行:
```bash
bundle exec rake apple:cache:clear_knowledge
```

scoped task が無い場合は **本 Task 17 の前** に、 Rakefile に scoped task (`task "apple:cache:clear_knowledge" do; FileUtils.rm_rf(File.join(AppleSDKMac.cache_dir, "knowledge")); end` 相当) を追加し、 別 commit (`chore(rake): add apple:cache:clear_knowledge scoped task`) で landing してから本 Step を進める。 直 `rm -rf` 禁止 (memory `cache_clear_via_rake_task`)。

- [ ] **Step 2: detached rebuild 起動 (~50+ 分想定)**

```bash
bundle exec rake apple:knowledge:rebuild_async
```

memory `~/dev/src/CLAUDE.md` 「ロングバッチ実行パターン」 に従う:
- `screen -dmS` で detached
- `tmp/longrun/<name>.log` に log
- 完了は `grep "^DONE:" tmp/longrun/<name>.log` で確認

screen session 名 / log path は rake task 実装に依存、 起動後すぐ確認:

```bash
screen -ls
ls tmp/longrun/
```

- [ ] **Step 3: 完了待機 (Claude のターン終了、 後続ターンで再開)**

このタスクは長時間処理なので、 本 step 到達時に Claude のターンを終了させる。 後続ターンで以下確認:

```bash
grep "^DONE:" tmp/longrun/<name>.log    # exit code 確認
tail -50 tmp/longrun/<name>.log         # 最終 log
```

- [ ] **Step 4: KB stats 確認**

```bash
bundle exec rake apple:knowledge:stats  # 存在する場合
# or 同等の確認 (irb 内):
# ruby -r apple_sdk_mac -e 'p AppleSDKMac.knowledge_cache.stats'
```

Expected:
- `framework_count` >= 既存値 (退行無し)
- `symbol_count` >= 既存値
- `kind_breakdown` に function / instance_method / class_method / instance_property / class etc が含まれること

新 column が populate されとるか確認:
```bash
# sqlite3 経由で stats
sqlite3 ~/.cache/rb-apple-sdk-mac/knowledge/*.sqlite "SELECT COUNT(*) FROM symbols WHERE is_throws = 1"
sqlite3 ~/.cache/rb-apple-sdk-mac/knowledge/*.sqlite "SELECT COUNT(*) FROM symbols WHERE is_async = 1"
sqlite3 ~/.cache/rb-apple-sdk-mac/knowledge/*.sqlite "SELECT COUNT(*) FROM symbols WHERE return_ownership = 'retained'"
sqlite3 ~/.cache/rb-apple-sdk-mac/knowledge/*.sqlite "SELECT COUNT(*) FROM symbols WHERE unsupported_pattern IS NOT NULL"
```

各 column が 0 件やったら importer 拡張が動いてへん → debug。 期待値:
- is_throws / is_async = 数百〜千件 (Foundation / AVFoundation 等の async/throws API)
- return_ownership = 'retained' = 数百件 (CF*Create* / CF*Copy* + 明示 attribute 付き)
- unsupported_pattern != NULL = 数十〜数百件 (macro / inline / result builder)

- [ ] **Step 5: 全 suite green 最終確認**

```bash
bundle exec rake test
cd knowledge && bundle exec rake test
```

Expected: 両方 green。

- [ ] **Step 6: Phase 1 完了 commit (KB rebuild は artefact 系で git に上げへん、 確認結果を CHANGELOG 等に書くだけ; 本 step は記述変更が無ければ skip)**

KB の sqlite は `.gitignore` 配下なので commit 不要。 もし `CHANGELOG.md` などにフェーズ完了 entry を書く運用なら本 step で commit。

---

## Task 18: Phase 1 完了の open items 整理 + Phase 2 spec confirm

**目的:** spec の open items の Phase 1 範囲分を解消 / 既知のまま phase 2 に lift、 Phase 1 completion mark。

**Files:**
- Modify: `docs/superpowers/specs/2026-05-14-deterministic-runtime-mcp-helper-design.md` Section 17 (open items の Phase 1 部分を「resolved」 表示 / Phase 2 部分はそのまま)

- [ ] **Step 1: open items に Phase 1 完了 update を inline 追記**

spec Section 17 の以下 open item を更新:

- Section 4.4 robotex gem 選定 → Phase 4 (MCP) で確定 (本 phase scope 外)、 そのまま open
- Section 8 docc archive JSON schema バージョン依存性 → Phase 4 (MCP) で確定、 そのまま open
- Section 11 smoke test 各 framework 代表 symbol list → Phase 5 で確定、 そのまま open
- Section 4.3 setter glue Ruby syntax → Phase 2 で確定、 そのまま open

Phase 1 (Section 2, 3) の implementation で発見した追加事項を Section 17 に append:

```markdown
### Phase 1 結果 (2026-05-14 完了)

- [x] SCHEMA_VERSION 9 bump 完了、 既存 cache は migrate 経由 invalidate 動作確認
- [x] clang importer の _Nullable / cf_returns_retained / typed block / static inline / function macro capture 全 fixture test green
- [x] swift_overlay importer の effect flags / labels / default values / Optional / enum cases / is_settable / macro marker capture 全 test green
- [x] KnowledgeCache lookup_symbol / lookup_klass_method 戻り Hash に Phase 1 metadata expose
- [x] apple:knowledge:rebuild_async smoke run で 全 framework re-import、 stats 退行無しを確認
- [ ] Phase 2 (emitter completeness) で消化する KB record を実装中に再点検する余地、 既存 emitter test 単体での観察は phase 2 開始時に取る

(以下 phase 2 / 3 / 4 / 5 の open items は既存記述のまま継続)
```

- [ ] **Step 2: commit**

```bash
git add docs/superpowers/specs/2026-05-14-deterministic-runtime-mcp-helper-design.md
git commit -m "$(cat <<'EOF'
docs(specs): mark phase 1 (Knowledge Base completeness) complete

Phase 1 result section を spec に append。 SCHEMA_VERSION 9 / importer
拡張 / KnowledgeCache expose 全 task の TDD green を記録、 残 phase 2-5
の open items を継続項目として残す。

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 1 完了基準

- [ ] 全 18 task の checkbox が完了
- [ ] `bundle exec rake test` (主 gem) full green
- [ ] `cd knowledge && bundle exec rake test` (sub-gem) full green
- [ ] `apple:knowledge:rebuild_async` 完了、 SCHEMA_VERSION 9 schema で全 framework ingest 成功
- [ ] sqlite3 stats で新 column populate 確認 (is_throws / is_async / return_ownership / unsupported_pattern いずれも非 0 件)
- [ ] commit log が Conventional Commits / Co-Authored-By 全件遵守
- [ ] main 直 push は user handoff (memory rule)

---

## Phase 2-5 outline (本 plan scope 外、 各 phase 完了後 writing-plans で詳細化)

### Phase 2 — Emitter completeness (spec Section 4 + 5 + 6)

`lib/apple_sdk_mac/glue_compiler/template_generator.rb` を KB metadata 全消化に書き換え。 signature 文字列 parse / naming heuristic / 手書き route map を全廃。 static rule 例外検出 + rich diagnostic surface。

主要 task:
- emitter が KB の is_throws / is_async / is_failable を読んで分岐
- emitter が return_ownership を読んで CF auto-arc 判定
- emitter が callback_signature_json を読んで pillar route auto-select、 未登録 shape は raise
- emitter が parameters_json の external_label / internal_name を読んで Swift bridge call 生成
- emitter が unsupported_pattern を検出して raise (AppleSDKMac::UnsupportedPatternError)
- Exception hierarchy 整備 (Section 6)
- 各 ruby exception class の diagnostic message 整備

### Phase 3 — Lazy transparent namespace + bootstrap! deprecation (spec Section 1)

`lib/apple_sdk_mac.rb` の Apple Box に const_missing / method_missing 配線。 `namespace_builder.rb` を lazy install path 主流に。 `dispatcher.rb` の LLM fallback path を削除。 `bootstrap!` を no-op alias 化。

### Phase 4 — MCP server 拡張 (spec Section 7 + 8 + 9)

`mcp/` sub-gem に search_apple_api / lookup_symbol / generate_ruby_snippet / suggest_related / suggest_wrapper_template / lookup_documentation の endpoint 追加。 web fetch infrastructure (allow list + 2s rate limit + robots.txt) 実装。 docc archive parser 実装。

### Phase 5 — IRB autocomplete + release_quality_smoke_test + README (spec Section 10 + 11 + 12)

`irb/` sub-gem の reline hook を lazy namespace 経路で動作確認。 :show_doc を MCP lookup_documentation 経由化。 release_quality_smoke_test 全 framework 代表 symbol scaffold + green まで importer / emitter / dispatcher loop。 README 修正 (`bootstrap!` を optional pre-warm 化、 KB miss = gem bug 文言追加、 MCP 章追加)。

---

## Execution handoff

Plan complete and saved to `docs/superpowers/plans/2026-05-14-deterministic-runtime-phase1-knowledge-base-completeness.md`.

Two execution options:

1. **Subagent-Driven (recommended)** — Phase 1 の 18 task を 1 task / subagent dispatch で進行、 task 間に review、 fast iteration、 main context 汚染最小。 superpowers:subagent-driven-development を使う。
2. **Inline Execution** — 本 session 内で executing-plans skill で task batch 実行、 commit 単位の checkpoint で review。

どっち?
