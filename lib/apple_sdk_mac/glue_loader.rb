# frozen_string_literal: true

module AppleSDKMac
  class GlueLoader
    def initialize
      @dylib_handles = {}
      @symbol_pointers = {}
    end

    def load(dylib_path:, exported_symbol:)
      return @symbol_pointers[exported_symbol] if @symbol_pointers.key?(exported_symbol)
      handle = @dylib_handles[dylib_path] ||= AppleSDKMacRuntime.dlopen_glue(dylib_path)
      ptr = AppleSDKMacRuntime.dlsym_glue(handle, exported_symbol)
      @symbol_pointers[exported_symbol] = ptr
      ptr
    end

    def invoke(fn_ptr, args)
      AppleSDKMacRuntime.invoke_glue(fn_ptr, args)
    end
  end
end
