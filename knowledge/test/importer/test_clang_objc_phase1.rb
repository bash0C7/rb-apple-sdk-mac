# frozen_string_literal: true
require "test_helper"
require "tmpdir"
require "json"
require "rb_apple_sdk_knowledge/store"
require "rb_apple_sdk_knowledge/importer/clang_objc"

# Phase 1 Task 3: ObjC `_Nullable` / `_Nonnull` per-parameter capture.
# The HeaderParser walks clang's JSON AST and now emits ObjCMethodDecl
# symbols; per-parameter `nullable:` boolean lifts the attribute into
# `parameters_json` so emitters can pick Qnil-tolerant marshallers
# without re-parsing qual_type strings at codegen time.
class TestClangObjcImporterPhase1 < Test::Unit::TestCase
  def test_nullable_attribute_captured_per_parameter
    Dir.mktmpdir do |dir|
      header = File.join(dir, "TestFW.h")
      # Foundation import is required: without it, clang collapses unknown
      # ObjC class types to `id` and strips the `_Nullable` / `_Nonnull`
      # annotations from qual_type, so the importer would have no fixture
      # to capture from. Real Apple SDK headers always #import the parent
      # framework before declaring annotated APIs.
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

  # Phase 1 T3 follow-up: clang AST exposes `instance: true|false` on
  # ObjCMethodDecl. The importer must lift `+` form class methods to
  # kind="class_method" so Phase 2 dispatch can route to the metaclass
  # call site instead of the instance one.
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

  # Phase 1 T3 follow-up: content_hash salt must include parameter types
  # so overloaded selectors with identical (framework, parent_name, name,
  # abi, signature) but divergent parameter types do not collide.
  # We construct two parse-time-independent headers that each declare
  # `@interface TestObj : NSObject` with the same selector `apply:` but
  # different parameter types. Each `import_file` runs clang as its own
  # translation unit, so duplicate-class redeclaration does not error.
  # Before the salt fix, both rows share content_hash and ON CONFLICT
  # collapses them to a single symbol row.
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

  # Phase 1 T4: clang exposes `cf_returns_retained` / `NS_RETURNS_RETAINED`
  # as a `CFReturnsRetainedAttr` / `NSReturnsRetainedAttr` child of the
  # function or method decl. The importer lifts that into the
  # `return_ownership = "retained"` schema column so emitters stop
  # depending on the `Copy` / `Create` naming heuristic. Annotation-less
  # function rows stay NULL — the heuristic remains as the last-resort
  # fallback until phase 2 retires it.
  def test_cf_returns_retained_captured_to_return_ownership
    Dir.mktmpdir do |dir|
      header = File.join(dir, "TestFW.h")
      # Foundation #import transitively provides `CFStringRef`; redefining
      # the typedef locally collides with CoreFoundation's `__CFString`
      # forward decl. Rely on the SDK header for the type and only
      # declare the two function prototypes the test cares about.
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
end
