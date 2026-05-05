# frozen_string_literal: true
require "foundation_model_mac"
require_relative "template_generator"

module AppleSDKMac
  class GlueCompiler
    class LLMGenerator
      WORKED_EXAMPLE = <<~SWIFT.freeze
        // Worked example: int input + string return path (rb_num2ll / rb_str_new_cstr).
        //   const char * AcmeCopyTitle(int id);
        // Note: this example does NOT cover string-input marshalling. For a string
        // input, use template_generator.rb's pattern: var v_i = argv[i] then
        // rb_string_value_cstr(&v_i) — argv[i] alone is UInt, not the
        // UnsafeMutablePointer<UInt> the rb_* function requires.
        // in framework AcmeFW, glue_id deadbeef. This example is fully
        // self-contained: the @_silgen_name header block appears below exactly
        // as it must appear in every generated file. Substitute the framework,
        // glue_id, symbol, and per-parameter marshalling for the requested
        // signature.
        import AcmeFW
        import Foundation

        #{TemplateGenerator::HEADER}
        @c
        public func glue_deadbeef_AcmeCopyTitle(
            _ argv: UnsafePointer<UInt>, _ argc: Int32
        ) -> UInt {
            let id: Int64 = rb_num2ll(argv[0])
            let cstr = AcmeCopyTitle(Int32(id))
            if cstr == nil { rb_raise(rb_eRuntimeError, "AcmeCopyTitle returned NULL") }
            return rb_str_new_cstr(cstr!)
        }
      SWIFT

      # Rules 5/6/7 below are positive-only ("use rb_* via @_silgen_name") and do not
      # name the phantom APIs they guard against, because the offline contract tests
      # in test/llm_generator_test.rb assert these strings are absent from INSTRUCTIONS:
      #   - Rule 5 guards against Marshal.fromRubyXXX (planned helper, never implemented)
      #   - Rule 6 guards against Marshal.toRuby (planned helper, never implemented)
      #   - Rule 7 guards against ErrorBridge.rb_raise_via_runtime (deleted in b262e18)
      #            and ConformanceBridge.lookup with the planned (symbol:, args:) signature.
      # Rule 2's prohibition list avoids the literal string `@c-attributed` (hyphenated form)
      # because that string was the original GATE 5 trigger; the contract test
      # test_instructions_do_not_reintroduce_at_c_attributed_prose guards against it.
      # See docs/superpowers/specs/2026-05-05-llm-fallback-prompt-alignment-design.md.
      INSTRUCTIONS = <<~TXT.freeze
        You generate Swift glue code for the rb-apple-sdk-mac runtime bridge.

        SECTION 1 — HARD REQUIREMENTS

        1. Output Swift source only. No prose, no markdown fences, no commentary.
        2. Output exactly one top-level function with this exact shape (note:
           bare `@c` on its own line, then `public func` on the next line):

               @c
               public func glue_<glue_id>_<symbol>(_ argv: UnsafePointer<UInt>, _ argc: Int32) -> UInt

           No `@c("name")`, no hyphenated `@c` forms, no other attribute spelling.
        3. Allowed imports: the target Apple framework, and `Foundation`.
           Nothing else. Do NOT import `AppleSDKMacRuntime`.
        4. Include the @_silgen_name header block (Section 2 below) verbatim,
           before the function definition. Do not add, remove, or rename any
           declaration in it.
        5. Marshal Ruby `VALUE` (`UInt`) inputs from `argv[i]` using only the
           rb_* symbols declared in the header: `rb_string_value_cstr`,
           `rb_num2ll`, `rb_num2ull`, `rb_num2dbl`. There is no helper
           module or wrapper class for argument marshalling — use the raw
           @_silgen_name-declared functions directly.
        6. Build the Ruby return value using only the rb_* symbols declared in
           the header (`rb_str_new_cstr`, `rb_ll2inum`, `rb_ull2inum`,
           `rb_float_new`) or the constants `Qnil`, `Qfalse`, `Qtrue`. There
           is no return-value wrapper or conversion helper — use the raw
           @_silgen_name-declared functions directly.
        7. On status-code errors from the target C function, call
           `rb_raise(rb_eRuntimeError, "<message>")`. Do not invent any other
           raise mechanism. The only way to raise a Ruby exception from Swift
           glue is via the @_silgen_name-declared `rb_raise` function.
        8. The only C call permitted inside the function body is the
           user-requested target symbol. No network, file, process, IPC,
           persistence, or environment-mutation APIs.
        9. For C function-pointer parameters (callbacks), emit a runtime
           branch:

               let cb: <CallbackType>?
               if argv[i] == Qnil {
                   cb = nil
               } else {
                   rb_raise(rb_eRuntimeError, "non-nil callback not yet supported")
               }

           Then pass `cb` to the C call. `rb_raise` is `-> Never`, so the
           compiler accepts `cb` as definitely-assigned in the only
           non-terminating branch.
        10. For raw `void *` parameters, mirror rule 9:

               let p: UnsafeMutableRawPointer?
               if argv[i] == Qnil {
                   p = nil
               } else {
                   p = UnsafeMutableRawPointer(bitPattern: Int(rb_num2ll(argv[i])))
               }

        SECTION 2 — @_silgen_name HEADER (copy verbatim)

        #{TemplateGenerator::HEADER}

        SECTION 3 — WORKED EXAMPLE

        #{WORKED_EXAMPLE}
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
