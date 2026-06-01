# frozen_string_literal: true
require "test_helper"
require "tmpdir"
require "apple_sdk_mac/glue_loader"
require "apple_sdk_mac/glue_compiler/swiftc_invoker"

class TestGlueLoader < Test::Unit::TestCase
  def test_loads_a_minimal_glue_and_invokes_it
    Dir.mktmpdir do |dir|
      src = File.join(dir, "g.swift")
      dylib = File.join(dir, "g.dylib")
      File.write(src, <<~SWIFT)
        import Foundation
        @c public func glue_minimal_passthrough(_ argv: UnsafePointer<UInt>, _ argc: Int32) -> UInt {
            return argv[0]
        }
      SWIFT
      ok, err = AppleSDKMac::GlueCompiler::SwiftcInvoker.new.compile(
        source_path: src, dylib_path: dylib
      )
      assert ok, err
      loader = AppleSDKMac::GlueLoader.new
      ptr = loader.load(dylib_path: dylib, exported_symbol: "glue_minimal_passthrough")
      result = loader.invoke(ptr, [42])
      assert_equal 42, result
    end
  end

  # 同一 exported symbol 名を別 dylib からロードしたとき、最初の dylib の
  # 関数ポインタをキャッシュ短絡せず、それぞれの dylib のポインタを返すこと。
  # round-trip 閉ループの retry は同名 symbol を再コンパイルするので、symbol 名だけで
  # キャッシュすると最初の attempt のポインタに固定され GREEN に到達できない。
  def test_load_keys_pointer_cache_by_dylib_path_not_symbol_name_alone
    Dir.mktmpdir do |dir|
      invoker = AppleSDKMac::GlueCompiler::SwiftcInvoker.new
      a = File.join(dir, "a.dylib")
      b = File.join(dir, "b.dylib")
      File.write(File.join(dir, "a.swift"), const_glue("glue_dup_sym", 100))
      File.write(File.join(dir, "b.swift"), const_glue("glue_dup_sym", 200))
      ok_a, err_a = invoker.compile(source_path: File.join(dir, "a.swift"), dylib_path: a)
      assert ok_a, err_a
      ok_b, err_b = invoker.compile(source_path: File.join(dir, "b.swift"), dylib_path: b)
      assert ok_b, err_b

      loader = AppleSDKMac::GlueLoader.new
      pa = loader.load(dylib_path: a, exported_symbol: "glue_dup_sym")
      assert_equal 100, loader.invoke(pa, [])
      pb = loader.load(dylib_path: b, exported_symbol: "glue_dup_sym")
      assert_equal 200, loader.invoke(pb, []),
                   "別 dylib の同名 symbol が最初の dylib のポインタで固定されてはならない"
    end
  end

  private

  # 引数を無視して固定 Fixnum を返す glue。(n << 1 | 1) は Ruby Fixnum エンコード。
  def const_glue(name, n)
    <<~SWIFT
      import Foundation
      @c public func #{name}(_ argv: UnsafePointer<UInt>, _ argc: Int32) -> UInt {
          return UInt(#{n}) << 1 | 1
      }
    SWIFT
  end
end
