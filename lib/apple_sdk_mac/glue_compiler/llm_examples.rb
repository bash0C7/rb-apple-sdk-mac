# frozen_string_literal: true

module AppleSDKMac
  class GlueCompiler
    # Worked-example catalogue for the LLM fallback Swift glue generator.
    # Eleven examples cover the four argument-marshalling shapes, four
    # async (Swift structured-concurrency) skeletons, and three ObjC
    # method-dispatch shapes. Each example is a complete Swift glue file
    # the LLM uses as a structural template.
    #
    # KEEP_FOR_FAMILY tells `instructions_for(family)` which single
    # example to keep when assembling the per-family instructions string;
    # the rest are pruned because the Foundation Models LM has a 4096-
    # token context window and the full bundle (~6.3k tokens) trips
    # exceededContextWindowSize on first respond().
    module LLMExamples
      INT_IN_STRING_OUT = <<~SWIFT.freeze
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

      STRING_IN_STATUS_OUT = <<~SWIFT.freeze
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

      STRUCT_IN = <<~SWIFT.freeze
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

      MULTI_OUT_HASH = <<~SWIFT.freeze
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

      # Async examples E1-E4. The fixed shape (DispatchSemaphore + Task { do {
      # try await ... } catch { captured = error } sema.signal() } + sema.wait()
      # + post-wait raise) is enforced by ValidationGates.async_shape. The LLM
      # only fills <body> and <T>; the skeleton is non-negotiable.
      ASYNC_E1 = <<~SWIFT.freeze
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

      ASYNC_E2 = <<~SWIFT.freeze
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

      ASYNC_E3 = <<~SWIFT.freeze
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

      ASYNC_E4 = <<~SWIFT.freeze
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

      # ObjC examples F1, F2, G. Use Swift's bridged class names (NSString,
      # VNImageRequestHandler, etc.) — no manual objc_msgSend. Returned ObjC
      # instances are bridged to Swift AnyObject; use
      # Unmanaged.passRetained(...).toOpaque() to encode the pointer
      # bit-pattern as a Ruby Integer, and the consumer uses unsafeBitCast
      # back to the class for subsequent method calls.
      OBJC_F1 = <<~SWIFT.freeze
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

      OBJC_F2 = <<~SWIFT.freeze
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

      OBJC_G = <<~SWIFT.freeze
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

      EXAMPLES = {
        int_in_string_out:    INT_IN_STRING_OUT,
        string_in_status_out: STRING_IN_STATUS_OUT,
        struct_in:            STRUCT_IN,
        multi_out_hash:       MULTI_OUT_HASH,
        async_e1:             ASYNC_E1,
        async_e2:             ASYNC_E2,
        async_e3:             ASYNC_E3,
        async_e4:             ASYNC_E4,
        objc_f1:              OBJC_F1,
        objc_f2:              OBJC_F2,
        objc_g:               OBJC_G
      }.freeze

      # Per kind-family, the single most-representative example to keep when
      # assembling the per-family instructions string. Foundation Models LM
      # has a 4096-token context window — the full 11-example bundle plus
      # hard-requirements prose runs ~6.3k tokens, so each family gets one
      # example and the rest are pruned out of INSTRUCTIONS for that family's
      # session.
      #   :c     — STRING_IN_STATUS_OUT carries the bound `var v0 = argv[0]`
      #            string-input idiom + status-OSStatus return pattern.
      #   :swift — ASYNC_E1 anchors the DispatchSemaphore + Task skeleton;
      #            E2-E4 are variations on the same shape.
      #   :objc  — OBJC_F2 (pure class method) covers the Swift-bridged
      #            class-name + Unmanaged.passRetained pattern. F1 (alloc/
      #            init) and G (completion block) are deferred to per-call
      #            instruction injection if their shapes ever surface.
      KEEP_FOR_FAMILY = {
        c:     [:string_in_status_out],
        swift: [:async_e1],
        objc:  [:objc_f2]
      }.freeze
    end
  end
end
