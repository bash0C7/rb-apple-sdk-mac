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
        Result.new(errors.empty?, errors)
      end

      private

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
          next if target_symbol.start_with?(pat.sub(/\W.*/, ""))
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
