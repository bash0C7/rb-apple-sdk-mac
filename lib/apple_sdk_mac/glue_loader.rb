# frozen_string_literal: true

module AppleSDKMac
  class GlueLoader
    def initialize
      @dylib_handles = {}
      @symbol_pointers = {}
    end

    def load(dylib_path:, exported_symbol:)
      # symbol 名だけでキャッシュすると、同名 symbol を別 dylib から再ロードした際に
      # 最初の dylib のポインタへ固定される (round-trip retry が新しい glue を再 invoke
      # できなくなる)。dylib パスと symbol 名の対でキー分けする。
      key = [dylib_path, exported_symbol]
      return @symbol_pointers[key] if @symbol_pointers.key?(key)
      handle = @dylib_handles[dylib_path] ||= AppleSDKMacRuntime.dlopen_glue(dylib_path)
      ptr = AppleSDKMacRuntime.dlsym_glue(handle, exported_symbol)
      @symbol_pointers[key] = ptr
      ptr
    end

    def invoke(fn_ptr, args)
      AppleSDKMacRuntime.invoke_glue(fn_ptr, args)
    end
  end
end
