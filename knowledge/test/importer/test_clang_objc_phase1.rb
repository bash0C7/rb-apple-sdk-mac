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
end
