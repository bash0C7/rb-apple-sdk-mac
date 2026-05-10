# frozen_string_literal: true
require "foundation_model_mac"
require_relative "template_generator"
require_relative "llm_examples"

module AppleSDKMac
  class GlueCompiler
    class LLMGenerator
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
        9. For C function-pointer parameters (callbacks):

           If the callback type is `MIDINotifyProc`, route the Ruby Block
           through the CallbackPillar register API:

               let cb: MIDINotifyProc?
               if argv[i] == Qnil {
                   cb = nil
               } else {
                   let cb_pid_v = rb_obj_id(argv[i])
                   let cb_reg = rb_gv_get("$__apple_sdk_mac_proc_registry")
                   rb_hash_aset(cb_reg, cb_pid_v, argv[i])
                   let cb_pid_u = rb_num2ull(cb_pid_v)
                   let cb_slot = runtime_callback_pillar_register_midi_notify(cb_pid_u)
                   if cb_slot < 0 { rb_raise(rb_eRuntimeError, "callback slot pool exhausted") }
                   let cb_raw = runtime_callback_pillar_get_midi_notify_fnptr(cb_slot)
                   cb = unsafeBitCast(UnsafeRawPointer(bitPattern: UInt(cb_raw))!, to: MIDINotifyProc.self)
               }

           For any other callback type that is not in the catalog, emit
           the unsupported-callback stub:

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

        SECTION 3 — WORKED EXAMPLES

        Eleven examples follow.

        Use Example A as the structural template; consult Example B for
        kind=string (the bound-var pattern is mandatory and not interchangeable
        with passing argv[i] directly), Example C for struct_in kinds (CGRect,
        MIDIPacketList, AudioStreamBasicDescription etc.), and Example D when
        the call has two or more out-parameters.

        Examples E1-E4 cover Swift structured concurrency. E1 = single await,
        E2 = TaskGroup parallel fan-out, E3 = async let for fixed-arity, E4 =
        @MainActor.run for main-thread-isolated APIs. The DispatchSemaphore +
        do/catch + sema.wait + post-wait raise skeleton is non-negotiable —
        ValidationGates rejects any await-bearing glue that does not match.

        Examples F1, F2, G cover ObjC method dispatch. F1 = alloc/init chain,
        F2 = pure class method, G = ObjC method that takes a noescape
        completion block. Use Swift's bridged class names — no manual
        objc_msgSend.

        #{LLMExamples::INT_IN_STRING_OUT}

        #{LLMExamples::STRING_IN_STATUS_OUT}

        #{LLMExamples::STRUCT_IN}

        #{LLMExamples::MULTI_OUT_HASH}

        #{LLMExamples::ASYNC_E1}

        #{LLMExamples::ASYNC_E2}

        #{LLMExamples::ASYNC_E3}

        #{LLMExamples::ASYNC_E4}

        #{LLMExamples::OBJC_F1}

        #{LLMExamples::OBJC_F2}

        #{LLMExamples::OBJC_G}
      TXT

      def initialize(model: nil, session: nil)
        # rb-foundation-model-mac's Session.new accepts instructions: only.
        # The model: parameter is preserved on this constructor for forward
        # compatibility but is currently ignored at the underlying session.
        _ = model
        # Kind-family-scoped sessions. The Foundation Models LM has a
        # 4096-token context window; the full INSTRUCTIONS bundle (all 11
        # worked examples + prose) hits ~6.3k tokens and trips
        # exceededContextWindowSize at the first respond(). We build a
        # smaller per-family instructions string at first call.
        # Sessions are NOT cached across generate() calls — each call gets
        # a fresh session to prevent conversation history from attempt N-1
        # pushing attempt N over the context window.
        @explicit_session = session
      end

      def generate(framework:, symbol:, glue_id:)
        family = kind_family(symbol[:kind])
        # Always create a FRESH session per generate() invocation. Reusing a
        # cached session accumulates conversation history across retries and
        # blows the 4096-token context window on attempt 2+.
        sess = foundation_model_session(family)
        prompt = build_prompt(framework, symbol, glue_id)
        response = sess.respond(to: prompt)
        return nil if response.nil? || response.strip.empty?
        cleaned = response.gsub(/\A```swift\n/, "").gsub(/\n```\z/, "").strip
        # Post-process to ensure the HEADER block is present even if the LLM
        # dropped the @_silgen_name declarations.
        ensure_header(cleaned, framework: framework)
      end

      def close
        @explicit_session&.close
      end

      private

      # Always returns a new session object so each generate() call starts
      # with a clean conversation context (no accumulated history).
      # Tests can stub this method on the singleton to intercept creation.
      def foundation_model_session(family)
        return @explicit_session if @explicit_session
        AppleFoundationModel::Session.new(instructions: instructions_for(family))
      end

      # Post-process the LLM-generated Swift source to ensure the canonical
      # HEADER block is present. The LLM occasionally drops the import lines
      # and @_silgen_name declarations, causing swiftc "cannot find 'rb_num2ll'
      # in scope" errors. We check for @_silgen_name presence (a reliable
      # marker for the full HEADER) and prepend the canonical block if missing.
      def ensure_header(swift_source, framework:)
        has_silgen = swift_source.include?("@_silgen_name(")
        has_fw_import = swift_source.include?("import #{framework}")
        has_foundation = swift_source.include?("import Foundation")
        return swift_source if has_silgen && has_fw_import && has_foundation

        header_block = "import #{framework}\nimport Foundation\n\n#{TemplateGenerator::HEADER}\n"
        # Strip any stray import lines the LLM may have added to avoid duplication.
        stripped = swift_source
          .gsub(/^import #{Regexp.escape(framework)}\s*\n?/, "")
          .gsub(/^import Foundation\s*\n?/, "")
        "#{header_block}#{stripped}"
      end

      def kind_family(kind)
        case kind.to_s
        when "objc_method_class", "objc_method_instance" then :objc
        when "swift_func", "swift_init", "swift_property" then :swift
        else :c
        end
      end

      # Build a kind-family-scoped instructions string by stripping the full
      # INSTRUCTIONS bundle of unrelated worked examples. The hard
      # requirements / prose stay verbatim; only the appended example
      # bodies are filtered. Order matters because some tests assert
      # specific snippets exist in INSTRUCTIONS — those tests read the
      # constant directly, not the per-family render.
      def instructions_for(family)
        keep_keys = LLMExamples::KEEP_FOR_FAMILY.fetch(family) {
          LLMExamples::KEEP_FOR_FAMILY[:c]
        }
        keep = keep_keys.map { |k| LLMExamples::EXAMPLES.fetch(k) }
        text = INSTRUCTIONS.dup
        (LLMExamples::EXAMPLES.values - keep).each { |ex| text = text.sub(ex, "") }
        text.gsub(/\n{3,}/, "\n\n")
      end

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

          MANDATORY: include the entire HEADER block at the top exactly as shown
          in Section 2 of the instructions — do not omit any @_silgen_name line.
          Failure to include the HEADER will cause compile errors ("cannot find
          'rb_num2ll' in scope", etc.). The HEADER must appear before the @c
          function definition, even if a worked example shows "HEADER omitted
          for brevity". Those examples abbreviated for readability only — the
          actual generated file must always contain the full HEADER verbatim.
        PROMPT
      end
    end
  end
end
