# frozen_string_literal: true
require "foundation_model_mac"
require_relative "template_generator"

module AppleSDKMac
  class GlueCompiler
    class LLMGenerator
      WORKED_EXAMPLE_INT_IN_STRING_OUT = <<~SWIFT.freeze
        // Example A — int input, string return (rb_num2ll / rb_str_new_cstr).
        //   const char * AcmeCopyTitle(int id);
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

      WORKED_EXAMPLE_STRING_IN_STATUS_OUT = <<~SWIFT.freeze
        // Example B — string input, status_int return.
        //   int AcmeRegisterTitle(const char *title);
        // CRITICAL: rb_string_value_cstr takes UnsafeMutablePointer<UInt>, NOT
        // UInt. Writing `rb_string_value_cstr(argv[0])` is a swiftc type error.
        // Bind argv[i] to a `var` first, then pass `&v<i>`. The @_silgen_name
        // HEADER block is omitted here for brevity; copy it verbatim from
        // Section 2 into every generated file.
        import AcmeFW
        import Foundation

        @c
        public func glue_cafef00d_AcmeRegisterTitle(
            _ argv: UnsafePointer<UInt>, _ argc: Int32
        ) -> UInt {
            var v0 = argv[0]
            let title = String(cString: rb_string_value_cstr(&v0))
            let status = AcmeRegisterTitle(title)
            if status != 0 { rb_raise(rb_eRuntimeError, "AcmeRegisterTitle failed") }
            return Qnil
        }
      SWIFT

      WORKED_EXAMPLE_STRUCT_IN = <<~SWIFT.freeze
        // Example C — struct input parameter (e.g. const MIDIPacketList *).
        // Build the struct field-by-field from a Ruby Hash via rb_hash_aref,
        // then pass `&<name>_struct` directly (Swift auto-promotes to
        // UnsafePointer<T> at the C call boundary). HEADER omitted for brevity.
        import AcmeFW
        import Foundation

        @c
        public func glue_b00b1e5_AcmeSendPacket(
            _ argv: UnsafePointer<UInt>, _ argc: Int32
        ) -> UInt {
            let pkt_h = argv[0]
            var pkt_struct = AcmePacket()
            pkt_struct.timeStamp = UInt64(rb_num2ull(rb_hash_aref(pkt_h, rb_str_new_cstr("timeStamp"))))
            pkt_struct.length = UInt16(rb_num2ull(rb_hash_aref(pkt_h, rb_str_new_cstr("length"))))
            let status = AcmeSendPacket(&pkt_struct)
            if status != 0 { rb_raise(rb_eRuntimeError, "AcmeSendPacket failed") }
            return Qnil
        }
      SWIFT

      # Phase 7 T3a — async Worked Examples E1-E4. The fixed shape (DispatchSemaphore
      # + Task { do { try await ... } catch { captured = error } sema.signal() } +
      # sema.wait() + post-wait raise) is enforced by ValidationGates.async_shape.
      # The LLM only fills <body> and <T>; the skeleton is non-negotiable.
      WORKED_EXAMPLE_ASYNC_E1 = <<~SWIFT.freeze
        // Example E1 — single Swift await. For `func foo() async throws -> T`,
        // ALWAYS emit this exact skeleton. The DispatchSemaphore + post-wait
        // raise pattern lets us synchronously block the calling Ruby thread
        // (which expects synchronous C-call semantics) while the Swift Task
        // runs on the cooperative thread pool.
        import AcmeFW
        import Foundation

        @c
        public func glue_aaaaaaaa_AcmeAsyncDouble(
            _ argv: UnsafePointer<UInt>, _ argc: Int32
        ) -> UInt {
            let x: Int64 = rb_num2ll(argv[0])
            let sema = DispatchSemaphore(value: 0)
            var result: Int64 = 0
            var captured: Error?
            Task {
                do { result = try await AcmeAsyncDouble(Int(x)) }
                catch { captured = error }
                sema.signal()
            }
            sema.wait()
            if let e = captured { rb_raise(rb_eRuntimeError, "\\(e)") }
            return rb_ll2inum(result)
        }
      SWIFT

      WORKED_EXAMPLE_ASYNC_E2 = <<~SWIFT.freeze
        // Example E2 — TaskGroup parallel fan-out. Use withThrowingTaskGroup
        // when the call shape is "fire N concurrent async ops, collect all
        // results". The outer skeleton (sema/Task/do/catch/signal/wait) is
        // identical to E1 — only the <body> changes.
        import AcmeFW
        import Foundation

        @c
        public func glue_bbbbbbbb_AcmeFanOut(
            _ argv: UnsafePointer<UInt>, _ argc: Int32
        ) -> UInt {
            let sema = DispatchSemaphore(value: 0)
            var results: [Int64] = []
            var captured: Error?
            Task {
                do {
                    results = try await withThrowingTaskGroup(of: Int64.self) { group in
                        for k in 0..<3 {
                            group.addTask { try await AcmeFetch(k) }
                        }
                        var acc: [Int64] = []
                        for try await v in group { acc.append(v) }
                        return acc
                    }
                } catch { captured = error }
                sema.signal()
            }
            sema.wait()
            if let e = captured { rb_raise(rb_eRuntimeError, "\\(e)") }
            // Marshal Array<Int64> via runtime Marshal pillar helper.
            // For brevity, the array-marshalling helper is omitted from this
            // example — refer to the runtime Marshal pillar when constructing
            // multi-element returns.
            return Qnil
        }
      SWIFT

      WORKED_EXAMPLE_ASYNC_E3 = <<~SWIFT.freeze
        // Example E3 — async let for fixed-arity parallelism. Cleaner than
        // TaskGroup when the count is known and types are heterogeneous.
        import AcmeFW
        import Foundation

        @c
        public func glue_cccccccc_AcmePairFetch(
            _ argv: UnsafePointer<UInt>, _ argc: Int32
        ) -> UInt {
            let sema = DispatchSemaphore(value: 0)
            var captured: Error?
            var x: Int64 = 0
            var y: Int64 = 0
            Task {
                do {
                    async let a = AcmeFetchA()
                    async let b = AcmeFetchB()
                    let pair = try await (a, b)
                    x = pair.0; y = pair.1
                } catch { captured = error }
                sema.signal()
            }
            sema.wait()
            if let e = captured { rb_raise(rb_eRuntimeError, "\\(e)") }
            let h = rb_hash_new()
            rb_hash_aset(h, rb_str_new_cstr("x"), rb_ll2inum(x))
            rb_hash_aset(h, rb_str_new_cstr("y"), rb_ll2inum(y))
            return h
        }
      SWIFT

      WORKED_EXAMPLE_ASYNC_E4 = <<~SWIFT.freeze
        // Example E4 — @MainActor-isolated work. Use await MainActor.run
        // when the API requires main-thread execution (common for AppKit /
        // UIKit). Outer skeleton unchanged from E1.
        import AcmeFW
        import Foundation

        @c
        public func glue_dddddddd_AcmeMainActorWork(
            _ argv: UnsafePointer<UInt>, _ argc: Int32
        ) -> UInt {
            let sema = DispatchSemaphore(value: 0)
            var result: Int64 = 0
            var captured: Error?
            Task {
                do { result = try await MainActor.run { AcmeMainActorOnlyWork() } }
                catch { captured = error }
                sema.signal()
            }
            sema.wait()
            if let e = captured { rb_raise(rb_eRuntimeError, "\\(e)") }
            return rb_ll2inum(result)
        }
      SWIFT

      # Phase 7 T3b — ObjC Worked Examples F1, F2, G. Use Swift's bridged
      # class names (NSString, VNImageRequestHandler, etc.) — no manual
      # objc_msgSend. Returned ObjC instances are bridged to Swift AnyObject;
      # use Unmanaged.passRetained(...).toOpaque() to encode the pointer
      # bit-pattern as a Ruby Integer, and the consumer uses unsafeBitCast
      # back to the class for subsequent method calls.
      WORKED_EXAMPLE_OBJC_F1 = <<~SWIFT.freeze
        // Example F1 — ObjC alloc/init chain. The Swift initializer call
        // is what produces the +1-retained instance; passRetained encodes
        // its raw pointer for round-trip through Ruby.
        import Vision
        import Foundation

        @c
        public func glue_f1f1f1f1_VNImageRequestHandler_initWithCGImage_options(
            _ argv: UnsafePointer<UInt>, _ argc: Int32
        ) -> UInt {
            let cg_raw = UInt(rb_num2ull(argv[0]))
            let img = unsafeBitCast(OpaquePointer(bitPattern: cg_raw)!, to: CGImage.self)
            let handler = VNImageRequestHandler(cgImage: img, options: [:])
            let raw = Unmanaged.passRetained(handler).toOpaque()
            return rb_ull2inum(UInt64(UInt(bitPattern: raw)))
        }
      SWIFT

      WORKED_EXAMPLE_OBJC_F2 = <<~SWIFT.freeze
        // Example F2 — pure ObjC class method (e.g. +stringWithUTF8String:).
        // No instance to alloc/init; the class method itself produces the
        // +1-retained NSString.
        import Foundation

        @c
        public func glue_f2f2f2f2_NSString_stringWithUTF8String(
            _ argv: UnsafePointer<UInt>, _ argc: Int32
        ) -> UInt {
            var v0 = argv[0]
            let cstr = rb_string_value_cstr(&v0)
            guard let s = NSString(utf8String: cstr) else { return Qnil }
            let raw = Unmanaged.passRetained(s).toOpaque()
            return rb_ull2inum(UInt64(UInt(bitPattern: raw)))
        }
      SWIFT

      WORKED_EXAMPLE_OBJC_G = <<~SWIFT.freeze
        // Example G — ObjC method that takes a noescape completion block.
        // The block is `block_nilable` per the AST; the marshaller emits a
        // stack-local @convention(block) literal pinned to runtime_proc_registry.
        // Errors thrown from `try` paths convert to NSError on the bridge.
        import Vision
        import Foundation

        @c
        public func glue_gggggggg_VNImageRequestHandler_performRequests(
            _ argv: UnsafePointer<UInt>, _ argc: Int32
        ) -> UInt {
            let h_raw = UInt(rb_num2ull(argv[0]))
            let handler = unsafeBitCast(OpaquePointer(bitPattern: h_raw)!,
                                        to: VNImageRequestHandler.self)
            let r_raw = UInt(rb_num2ull(argv[1]))
            let request = unsafeBitCast(OpaquePointer(bitPattern: r_raw)!,
                                        to: VNRequest.self)
            do {
                try handler.perform([request])
                return Qnil
            } catch let e as NSError {
                rb_raise(rb_eRuntimeError, "\\(e.localizedDescription)")
            }
            return Qnil
        }
      SWIFT

      WORKED_EXAMPLE_MULTI_OUT_HASH = <<~SWIFT.freeze
        // Example D — multi-out-param call returning a Ruby Hash with named keys.
        //   OSStatus AcmeMakePair(AcmeRef *outA, AcmeRef *outB);
        // For symbols with ≥2 out-params, declare each `var <name>: <Type> = <Type>()`,
        // call with `&<name>` per arg, then assemble a hash via rb_hash_new + per-name
        // rb_hash_aset. HEADER omitted for brevity.
        import AcmeFW
        import Foundation

        @c
        public func glue_facef00d_AcmeMakePair(
            _ argv: UnsafePointer<UInt>, _ argc: Int32
        ) -> UInt {
            var outA: AcmeRef = AcmeRef()
            var outB: AcmeRef = AcmeRef()
            let status = AcmeMakePair(&outA, &outB)
            if status != 0 { rb_raise(rb_eRuntimeError, "AcmeMakePair failed") }
            let multi_out_h = rb_hash_new()
            rb_hash_aset(multi_out_h, rb_str_new_cstr("outA"), rb_ull2inum(UInt64(outA)))
            rb_hash_aset(multi_out_h, rb_str_new_cstr("outB"), rb_ull2inum(UInt64(outB)))
            return multi_out_h
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
           the legacy stub:

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

        #{WORKED_EXAMPLE_INT_IN_STRING_OUT}

        #{WORKED_EXAMPLE_STRING_IN_STATUS_OUT}

        #{WORKED_EXAMPLE_STRUCT_IN}

        #{WORKED_EXAMPLE_MULTI_OUT_HASH}

        #{WORKED_EXAMPLE_ASYNC_E1}

        #{WORKED_EXAMPLE_ASYNC_E2}

        #{WORKED_EXAMPLE_ASYNC_E3}

        #{WORKED_EXAMPLE_ASYNC_E4}

        #{WORKED_EXAMPLE_OBJC_F1}

        #{WORKED_EXAMPLE_OBJC_F2}

        #{WORKED_EXAMPLE_OBJC_G}
      TXT

      def initialize(model: nil, session: nil)
        # rb-foundation-model-mac's Session.new accepts instructions: only.
        # The model: parameter is preserved on this constructor for forward
        # compatibility but is currently ignored at the underlying session.
        _ = model
        # Phase 7 — kind-family-scoped sessions. The Foundation Models LM
        # has a 4096-token context window; the full INSTRUCTIONS bundle
        # (all 11 worked examples + prose) hits ~6.3k tokens and trips
        # exceededContextWindowSize at the very first respond(). We
        # build a smaller per-family instructions string at first call
        # and cache the session by family. Tests that read the
        # INSTRUCTIONS constant continue to see the canonical bundle.
        @explicit_session = session
        @session_cache = {}
      end

      def generate(framework:, symbol:, glue_id:)
        sess = session_for(symbol[:kind])
        prompt = build_prompt(framework, symbol, glue_id)
        response = sess.respond(to: prompt)
        return nil if response.nil? || response.strip.empty?
        response.gsub(/\A```swift\n/, "").gsub(/\n```\z/, "").strip
      end

      def close
        @explicit_session&.close
        @session_cache.each_value(&:close)
        @session_cache.clear
      end

      private

      def session_for(kind)
        return @explicit_session if @explicit_session
        family = kind_family(kind)
        @session_cache[family] ||= AppleFoundationModel::Session.new(
          instructions: instructions_for(family)
        )
      end

      def kind_family(kind)
        case kind.to_s
        when "objc_method_class", "objc_method_instance" then :objc
        when "swift_func", "swift_init", "swift_property" then :swift
        else :c
        end
      end

      # Build a kind-family-scoped instructions string by stripping the
      # full INSTRUCTIONS bundle of unrelated worked examples. The hard
      # requirements / prose stay verbatim; only the appended example
      # bodies are filtered. Order matters because some tests assert
      # specific snippets exist in INSTRUCTIONS — those tests read the
      # constant directly, not the per-family render.
      # Foundation Models LM has a 4096-token context window. Even one
      # worked example per family + the hard-requirements prose runs ~3.5k
      # tokens, so each family gets the SINGLE most-representative example
      # rather than every variation. The unused examples are pruned out
      # of INSTRUCTIONS for that family's session.
      #   :c     — STRING_IN_STATUS_OUT carries the bound `var v0 = argv[0]`
      #            string-input idiom + status-OSStatus return pattern.
      #   :swift — ASYNC_E1 anchors the DispatchSemaphore + Task skeleton;
      #            E2-E4 are variations on the same shape.
      #   :objc  — OBJC_F2 (pure class method) covers the Swift-bridged
      #            class-name + Unmanaged.passRetained pattern. F1 (alloc/
      #            init) and G (completion block) are deferred to per-call
      #            instruction injection if their shapes ever surface.
      FAMILY_KEEP = {
        c:     [WORKED_EXAMPLE_STRING_IN_STATUS_OUT],
        swift: [WORKED_EXAMPLE_ASYNC_E1],
        objc:  [WORKED_EXAMPLE_OBJC_F2]
      }.freeze
      ALL_KNOWN_EXAMPLES = [
        WORKED_EXAMPLE_INT_IN_STRING_OUT, WORKED_EXAMPLE_STRING_IN_STATUS_OUT,
        WORKED_EXAMPLE_STRUCT_IN, WORKED_EXAMPLE_MULTI_OUT_HASH,
        WORKED_EXAMPLE_ASYNC_E1, WORKED_EXAMPLE_ASYNC_E2,
        WORKED_EXAMPLE_ASYNC_E3, WORKED_EXAMPLE_ASYNC_E4,
        WORKED_EXAMPLE_OBJC_F1, WORKED_EXAMPLE_OBJC_F2, WORKED_EXAMPLE_OBJC_G
      ].freeze
      def instructions_for(family)
        keep = FAMILY_KEEP.fetch(family) { FAMILY_KEEP[:c] }
        text = INSTRUCTIONS.dup
        (ALL_KNOWN_EXAMPLES - keep).each { |ex| text = text.sub(ex, "") }
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
        PROMPT
      end
    end
  end
end
