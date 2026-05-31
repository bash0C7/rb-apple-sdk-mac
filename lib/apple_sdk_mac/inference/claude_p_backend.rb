# frozen_string_literal: true

require "open3"
require_relative "backend"

module AppleSDKMac
  module Inference
    # `claude -p` ヘッドレスを subprocess で呼び、Knowledge Base symbol メタから
    # Swift glue source を生成する第一級 backend (PoC)。runner を inject 可能にして
    # subprocess を unit から切り離す。secret は一切扱わない (CLI 認証済み前提)。
    class ClaudePBackend < Backend
      DEFAULT_RUNNER = lambda do |prompt|
        out, _err, status = Open3.capture3("claude", "-p", prompt)
        status.success? ? out : nil
      end

      def initialize(runner: DEFAULT_RUNNER)
        @runner = runner
      end

      def name
        "claude_p"
      end

      def generate_glue(framework:, symbol:, glue_id:, exported:, seed: nil)
        prompt = build_prompt(framework: framework, symbol: symbol,
                              glue_id: glue_id, exported: exported, seed: seed)
        response = @runner.call(prompt)
        return nil if response.nil? || response.empty?
        extract_swift(response)
      end

      private

      def build_prompt(framework:, symbol:, glue_id:, exported:, seed: nil)
        seed_section = build_seed_section(seed)
        <<~PROMPT
          You are generating a Swift glue function that bridges a single Apple
          framework symbol to C ABI for the rb-apple-sdk-mac gem.

          Target framework: #{framework}
          Symbol: #{symbol[:name]}
          Kind: #{symbol[:kind]}
          Signature: #{symbol[:signature]}
          Parameters (JSON): #{symbol[:parameters_json]}

          HARD CONSTRAINTS (the output is statically validated; violations are rejected):
          - Emit exactly ONE `@c public func #{exported}(...)`.
          - Import ONLY: `import #{framework}`, `import Foundation`, `import AppleSDKMacRuntime`.
          - Do NOT use any of the following APIs:
            URLSession, NSURLConnection, URLRequest(, NWConnection,
            FileManager, FileHandle, Data(contentsOf:, String(contentsOf:,
            Bundle.main.url(forResource:, Process(, posix_spawn, system(,
            execve, NSXPCConnection, NSDistributedNotificationCenter,
            UserDefaults, Keychain, ProcessInfo.processInfo.environment[,
            objc_msgSend.
          - For CFType returns use Unmanaged.takeRetainedValue(); never manual CFRelease.
          - Return a value the C caller can consume (Int/Double/pointer/OpaqueRef).
          - If the function is async, wrap with DispatchSemaphore and Task { }.
          #{seed_section}
          Respond with ONLY a single ```swift fenced code block containing the
          function. No prose.
        PROMPT
      end

      # seed (rule_scaffold / context / failure_detail / last_glue) を prompt の
      # 追加セクションに展開。seed が nil または全 key 空なら空文字を返し、prompt は
      # 元の形を保つ。
      def build_seed_section(seed)
        return "" if seed.nil?
        parts = []
        if seed[:rule_scaffold] && !seed[:rule_scaffold].to_s.strip.empty?
          parts << "REFERENCE SCAFFOLD — emit glue with the SAME struct-key lookups, " \
                   "out-param handling, and exported function name:\n" \
                   "```swift\n#{seed[:rule_scaffold]}\n```"
        end
        if seed[:context] && !seed[:context].to_s.strip.empty?
          parts << "USER CONTEXT (use this to resolve the type/usage ambiguity):\n#{seed[:context]}"
        end
        if seed[:failure_detail] && !seed[:failure_detail].to_s.strip.empty?
          parts << "PREVIOUS ATTEMPT FAILED — fix the issue described:\n#{seed[:failure_detail]}"
        end
        if seed[:last_glue] && !seed[:last_glue].to_s.strip.empty?
          parts << "PREVIOUS (REJECTED) GLUE for reference:\n```swift\n#{seed[:last_glue]}\n```"
        end
        parts.empty? ? "" : "\n#{parts.join("\n\n")}\n"
      end

      # ```swift ... ``` を抽出。無ければ nil。
      def extract_swift(response)
        m = response.match(/```swift\s*\n(.*?)```/m)
        return nil unless m
        body = m[1].to_s.strip
        body.empty? ? nil : body
      end
    end
  end
end
