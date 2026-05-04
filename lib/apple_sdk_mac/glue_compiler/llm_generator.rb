# frozen_string_literal: true
require "foundation_model_mac"

module AppleSDKMac
  class GlueCompiler
    class LLMGenerator
      INSTRUCTIONS = <<~TXT.freeze
        You generate Swift glue code for the rb-apple-sdk-mac runtime bridge.
        STRICT RULES:
        1. Output exactly one @c-attributed public function named glue_<glue_id>_<symbol>.
        2. Function signature is exactly:
             func glue_<glue_id>_<symbol>(_ argv: UnsafePointer<UInt>, _ argc: Int32) -> UInt
        3. Allowed imports: the target Apple framework, AppleSDKMacRuntime, Foundation. No others.
        4. No network, file, process, IPC, persistence, or environment-mutation APIs may be called
           inside the function body, EXCEPT the user-requested target symbol itself.
        5. Marshal arguments via AppleSDKMacRuntime.Marshal.fromRubyXXX helpers.
        6. Marshal returns via AppleSDKMacRuntime.Marshal.toRuby.
        7. For async functions, wrap in AsyncBridge.runSync.
        8. For protocol/superclass shims, generate a separate Swift class conforming to the protocol;
           dispatch each required method via AppleSDKMacRuntime.ConformanceBridge.lookup.
        9. Output ONLY Swift source code. No prose, no markdown fences, no commentary.
      TXT

      def initialize(model: nil, session: nil)
        @session = session || AppleFoundationModel::Session.new(instructions: INSTRUCTIONS, model: model)
      end

      def generate(framework:, symbol:, glue_id:)
        prompt = build_prompt(framework, symbol, glue_id)
        response = @session.respond(to: prompt)
        return nil if response.nil? || response.strip.empty?
        response.gsub(/\A```swift\n/, "").gsub(/\n```\z/, "").strip
      end

      def close
        @session.close
      end

      private

      def build_prompt(framework, sym, glue_id)
        <<~PROMPT
          framework: #{framework}
          glue_id: #{glue_id}
          symbol_name: #{sym[:name]}
          kind: #{sym[:kind]}
          abi: #{sym[:abi]}
          signature: #{sym[:signature]}
          parameters_json: #{sym[:parameters_json]}

          Generate the Swift glue file as specified. Output Swift source only.
        PROMPT
      end
    end
  end
end
