# frozen_string_literal: true
require "test_helper"
require "tmpdir"
require "json"
require "rb_apple_sdk_knowledge/store"
require "rb_apple_sdk_knowledge/importer/clang_objc"

class TestClangObjcImporterPhase1 < Test::Unit::TestCase
  def test_nullable_attribute_captured_per_parameter
    Dir.mktmpdir do |dir|
      header = File.join(dir, "TestFW.h")
      File.write(header, <<~HEADER)
        #import <Foundation/Foundation.h>
        @interface TestObj : NSObject
        - (void)doStuff:(NSString * _Nullable)maybe with:(NSString * _Nonnull)required;
        @end
      HEADER
      db_path = File.join(dir, "k.sqlite")
      store = AppleSDKKnowledge::Store.open(db_path)
      AppleSDKKnowledge::Importer::ClangObjc.import_file(
        store: store, framework: "TestFW", file: header
      )
      sym = store.db.execute(
        "SELECT parameters_json FROM symbols WHERE name = ?", ["doStuff:with:"]
      ).first
      assert_not_nil sym, "doStuff:with: should be imported as a symbol"
      params = JSON.parse(sym[0])
      assert_equal 2, params.size
      assert_equal true,  params[0]["nullable"], "maybe is _Nullable so nullable=true"
      assert_equal false, params[1]["nullable"], "required is _Nonnull so nullable=false"
      store.close
    end
  end

  def test_objc_class_method_distinguished_from_instance_method
    Dir.mktmpdir do |dir|
      header = File.join(dir, "TestFW.h")
      File.write(header, <<~HEADER)
        #import <Foundation/Foundation.h>
        @interface TestObj : NSObject
        - (void)doInstance:(NSString * _Nullable)maybe;
        + (TestObj * _Nonnull)classFactory:(NSInteger)count;
        @end
      HEADER
      db_path = File.join(dir, "k.sqlite")
      store = AppleSDKKnowledge::Store.open(db_path)
      AppleSDKKnowledge::Importer::ClangObjc.import_file(
        store: store, framework: "TestFW", file: header
      )
      inst = store.db.execute("SELECT kind FROM symbols WHERE name = ?", ["doInstance:"]).first
      cls  = store.db.execute("SELECT kind FROM symbols WHERE name = ?", ["classFactory:"]).first
      assert_not_nil inst, "instance method doInstance: should be imported"
      assert_not_nil cls,  "class method classFactory: should be imported"
      assert_equal "instance_method", inst[0]
      assert_equal "class_method",    cls[0]
      store.close
    end
  end

  def test_overloaded_selectors_get_distinct_content_hash
    Dir.mktmpdir do |dir|
      header1 = File.join(dir, "Overload1.h")
      File.write(header1, <<~HEADER)
        #import <Foundation/Foundation.h>
        @interface TestObj : NSObject
        - (void)apply:(NSString * _Nullable)arg;
        @end
      HEADER
      header2 = File.join(dir, "Overload2.h")
      File.write(header2, <<~HEADER)
        #import <Foundation/Foundation.h>
        @interface TestObj : NSObject
        - (void)apply:(NSNumber * _Nullable)arg;
        @end
      HEADER
      db_path = File.join(dir, "k.sqlite")
      store = AppleSDKKnowledge::Store.open(db_path)
      AppleSDKKnowledge::Importer::ClangObjc.import_file(store: store, framework: "TestFW", file: header1)
      AppleSDKKnowledge::Importer::ClangObjc.import_file(store: store, framework: "TestFW", file: header2)
      rows = store.db.execute("SELECT id, content_hash, parameters_json FROM symbols WHERE name = ?", ["apply:"])
      assert_equal 2, rows.size,
        "parameter types が異なる同 selector は 2 entries (content_hash が param types を含めば collision せえへん)"
      hashes = rows.map { |r| r[1] }.uniq
      assert_equal 2, hashes.size, "content_hash must be distinct between overloads"
      store.close
    end
  end

  def test_cf_returns_retained_captured_to_return_ownership
    Dir.mktmpdir do |dir|
      header = File.join(dir, "TestFW.h")
      File.write(header, <<~HEADER)
        #import <Foundation/Foundation.h>
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

  def test_typed_block_parameter_lifts_callback_signature_json
    Dir.mktmpdir do |dir|
      header = File.join(dir, "TestFW.h")
      File.write(header, <<~HEADER)
        #import <Foundation/Foundation.h>
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
      store.close
    end
  end

  def test_static_inline_function_is_marked_unsupported_inline_only
    Dir.mktmpdir do |dir|
      header = File.join(dir, "TestFW.h")
      File.write(header, <<~HEADER)
        #import <Foundation/Foundation.h>
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
      assert_not_nil row1, "MyFastDouble が import されてへん"
      assert_equal "inline_only", row1[0],
        "static inline は dylib symbol 無し、 marker 必須"
      assert_not_nil row2, "MyRegularFunc が import されてへん"
      assert_nil row2[0],
        "通常 extern は marker 無し"
      store.close
    end
  end

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
      row1 = store.db.execute("SELECT unsupported_pattern, kind FROM symbols WHERE name = ?", ["MakeWidget"]).first
      row2 = store.db.execute("SELECT name FROM symbols WHERE name = ?", ["MY_CONSTANT"]).first
      assert_not_nil row1, "MakeWidget が import されてへん"
      assert_equal "function_macro", row1[0],
        "MakeWidget は function-like macro、 marker 必須"
      assert_equal "function", row1[1],
        "function-like macro は function kind で並びを揃える"
      assert_nil row2, "MY_CONSTANT は value macro、 既存挙動どおり import されへん"
      store.close
    end
  end
end
