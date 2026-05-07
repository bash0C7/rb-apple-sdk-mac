# frozen_string_literal: true

module AppleSDKMac
  class GlueCompiler
    class ValidationGates
      Result = Struct.new(:pass?, :errors)

      ALLOWED_IMPORTS_EXTRA = %w[AppleSDKMacRuntime Foundation].freeze

      BANNED_API_PATTERNS = [
        "URLSession", "NSURLConnection", "URLRequest(", "NWConnection",
        "FileManager", "FileHandle", "Data(contentsOf:", "String(contentsOf:",
        "Bundle.main.url(forResource:", "Process(", "posix_spawn", "system(",
        "execve", "NSXPCConnection", "NSDistributedNotificationCenter",
        "UserDefaults", "Keychain", "ProcessInfo.processInfo.environment["
      ].freeze

      def validate(swift, framework:, glue_id:, symbol:)
        errors = []
        check_imports(swift, framework, errors)
        check_banned_apis(swift, symbol, errors)
        check_shape(swift, glue_id, symbol, errors)
        check_async_shape(swift, errors)
        check_persistent_block_shape(swift, errors)
        check_autoarc_shape(swift, errors)
        check_objc_bridge_shape(swift, errors)
        Result.new(errors.empty?, errors)
      end

      private

      # Phase 7 T3c gates — enforce the LLM Worked Example shapes literally.
      # Malformed glue is rejected before swiftc invocation; LLMGenerator's
      # retry loop (DEFAULT_MAX_LLM_RETRIES = 6) gets a chance to converge.

      ASYNC_REQUIRED_PATTERNS = [
        [/DispatchSemaphore\(value:\s*0\)/, "DispatchSemaphore(value: 0)"],
        [/Task\s*\{/, "Task { ... }"],
        [/do\s*\{[^}]*try\s+await/m, "do { try await ... }"],
        [/catch\s*\{/, "catch { ... }"],
        [/sema\.signal\(\)/, "sema.signal()"],
        [/sema\.wait\(\)/, "sema.wait()"]
      ].freeze

      def check_async_shape(swift, errors)
        return unless swift.match?(/\bawait\b/)
        ASYNC_REQUIRED_PATTERNS.each do |re, label|
          unless swift.match?(re)
            errors << "GATE 6 async-shape violation: missing #{label} in await-bearing glue"
          end
        end
      end

      def check_persistent_block_shape(swift, errors)
        return unless swift.include?("BoxedBlockHandle")
        unless swift.include?("runtime_callback_register_block_persistent")
          errors << "GATE 7 persistent-block-shape: BoxedBlockHandle without runtime_callback_register_block_persistent"
        end
      end

      def check_autoarc_shape(swift, errors)
        return unless swift.include?("BoxedCFType")
        if swift.match?(/\bCFRelease\(/)
          errors << "GATE 8 autoarc-shape: manual CFRelease forbidden in cftype_ref_autoarc glue"
        end
        unless swift.include?("takeRetainedValue()")
          errors << "GATE 8 autoarc-shape: BoxedCFType requires Unmanaged.takeRetainedValue()"
        end
      end

      def check_objc_bridge_shape(swift, errors)
        if swift.match?(/\bobjc_msgSend\b/)
          errors << "GATE 9 objc-bridge-shape: manual objc_msgSend forbidden — import the framework module and use Swift's bridged class name"
        end
      end

      def check_imports(swift, framework, errors)
        imports = swift.lines.map(&:strip).select { |l| l.start_with?("import ") }
        seen = imports.map { |l| l.sub(/\Aimport\s+/, "").split(/[\s.]/, 2).first }
        allowed = [framework] + ALLOWED_IMPORTS_EXTRA
        seen.each do |imp|
          unless allowed.include?(imp)
            errors << "GATE 3 disallowed import: #{imp}"
          end
        end
      end

      def check_banned_apis(swift, target_symbol, errors)
        BANNED_API_PATTERNS.each do |pat|
          next unless swift.include?(pat)
          clean_pat = pat.sub(/\W.*/, "")
          next if target_symbol.start_with?(clean_pat)
          # T53e — Apple SDK の正規 NS-prefixed class (NSURLSession 等) を user が
          # 明示 discover した経路は target_symbol が `NS<Klass>_<member>` 形に
          # なる。 これらは安全な discover として banned 検査を bypass する。
          # LLM が任意に URLSession を持ち込む経路 (target_symbol="MIDIDispose"
          # 等) は引き続き ban。
          next if target_symbol.start_with?("NS" + clean_pat)
          errors << "GATE 4 banned API used: #{pat}"
        end
      end

      def check_shape(swift, glue_id, symbol, errors)
        c_exports = swift.scan(/@c\s+public\s+func\s+(\w+)/)
        if c_exports.empty?
          errors << "GATE 5 no @c public func found"
        elsif c_exports.length > 1
          errors << "GATE 5 multiple @c exports: #{c_exports.flatten.join(', ')}"
        else
          name = c_exports.flatten.first
          expected = "glue_#{glue_id}_#{symbol}"
          errors << "GATE 5 expected export #{expected}, got #{name}" unless name == expected
        end
      end
    end
  end
end
