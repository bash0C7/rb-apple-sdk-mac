# frozen_string_literal: true
require "json"
require "set"
require_relative "marshallers"
require_relative "swift_bridge_name"
require_relative "../selector_bridge"
require_relative "objc_marshalling"

module AppleSDKMac
  class GlueCompiler
    class TemplateGenerator
      # @_silgen_name declarations for the per-route CallbackPillar wrappers,
      # built from CALLBACK_PILLAR_ROUTES so adding a new signature is one YAML
      # entry + one Marshaller route map line — no manual HEADER edit.
      CALLBACK_BRIDGE_DECLS = ::AppleSDKMac::GlueCompiler::CALLBACK_PILLAR_ROUTES
        .values.uniq.map { |route|
          <<~SWIFT.chomp
            @_silgen_name("runtime_callback_pillar_register_#{route}")
            func runtime_callback_pillar_register_#{route}(_ procId: UInt64) -> Int32
            @_silgen_name("runtime_callback_pillar_get_#{route}_fnptr")
            func runtime_callback_pillar_get_#{route}_fnptr(_ slot: Int32) -> UInt64
          SWIFT
        }.join("\n").freeze

      HEADER = <<~SWIFT.freeze
        // CRuby symbols resolved at dlopen via -undefined dynamic_lookup
        @_silgen_name("rb_string_value_cstr")
        func rb_string_value_cstr(_ value: UnsafeMutablePointer<UInt>) -> UnsafePointer<CChar>
        @_silgen_name("rb_str_new_cstr")
        func rb_str_new_cstr(_ s: UnsafePointer<CChar>) -> UInt
        @_silgen_name("rb_num2ll")
        func rb_num2ll(_ v: UInt) -> Int64
        @_silgen_name("rb_num2ull")
        func rb_num2ull(_ v: UInt) -> UInt64
        @_silgen_name("rb_ll2inum")
        func rb_ll2inum(_ v: Int64) -> UInt
        @_silgen_name("rb_ull2inum")
        func rb_ull2inum(_ v: UInt64) -> UInt
        @_silgen_name("rb_num2dbl")
        func rb_num2dbl(_ v: UInt) -> Double
        @_silgen_name("rb_float_new")
        func rb_float_new(_ d: Double) -> UInt
        @_silgen_name("rb_raise")
        func rb_raise(_ klass: UInt, _ fmt: UnsafePointer<CChar>) -> Never
        @_silgen_name("rb_eRuntimeError")
        var rb_eRuntimeError: UInt
        @_silgen_name("rb_hash_new")
        func rb_hash_new() -> UInt
        @_silgen_name("rb_hash_aref")
        func rb_hash_aref(_ hash: UInt, _ key: UInt) -> UInt
        @_silgen_name("rb_hash_aset")
        func rb_hash_aset(_ hash: UInt, _ key: UInt, _ val: UInt) -> UInt
        @_silgen_name("rb_block_given_p")
        func rb_block_given_p() -> Int32
        @_silgen_name("rb_block_proc")
        func rb_block_proc() -> UInt
        @_silgen_name("rb_obj_id")
        func rb_obj_id(_ v: UInt) -> UInt
        @_silgen_name("rb_ary_entry")
        func rb_ary_entry(_ ary: UInt, _ off: Int) -> UInt
        @_silgen_name("rb_ary_new")
        func rb_ary_new() -> UInt
        @_silgen_name("rb_ary_push")
        func rb_ary_push(_ ary: UInt, _ val: UInt) -> UInt
        @_silgen_name("runtime_rb_array_len")
        func runtime_rb_array_len(_ ary: UInt) -> Int
        @_silgen_name("runtime_proc_registry_get")
        func runtime_proc_registry_get() -> UInt
        @_silgen_name("runtime_arc_box_cftype")
        func runtime_arc_box_cftype(_ raw: UInt) -> UInt
        @_silgen_name("runtime_arc_unbox_cftype")
        func runtime_arc_unbox_cftype(_ raw: UInt) -> UInt
        @_silgen_name("runtime_threading_enqueue")
        func runtime_threading_enqueue(_ procId: UInt64, _ arg: Int64)
        @_silgen_name("runtime_threading_enqueue_3")
        func runtime_threading_enqueue_3(_ procId: UInt64, _ a: Int64, _ b: Int64, _ c: Int64)
        @_silgen_name("runtime_callback_register_block_persistent")
        func runtime_callback_register_block_persistent(_ procId: UInt64) -> UInt64
        #{CALLBACK_BRIDGE_DECLS}

        let Qfalse: UInt = 0
        let Qnil:   UInt = 4
        let Qtrue:  UInt = 20
      SWIFT

      def initialize(knowledge_cache: nil)
        @kc = knowledge_cache
      end

      def generate(framework:, symbol:, glue_id:)
        # Kind dispatcher。Apple.discover の synth record で objc/swift kinds が
        # 来たら専用 emitter に routing。C-function 経路は既存 path を維持。
        # 未対応 kind は nil で LLM fallback へ流す。
        case symbol[:kind]
        when "objc_method_class"
          return emit_objc_class_method(framework: framework, symbol: symbol, glue_id: glue_id)
        when "objc_method_instance"
          return emit_objc_instance_method(framework: framework, symbol: symbol, glue_id: glue_id)
        when "swift_init"
          return emit_swift_init(framework: framework, symbol: symbol, glue_id: glue_id)
        when "swift_property"
          return emit_swift_property(framework: framework, symbol: symbol, glue_id: glue_id)
        when "swift_func"
          return emit_swift_func(framework: framework, symbol: symbol, glue_id: glue_id)
        end
        return nil unless symbol[:kind] == "function" && symbol[:abi] == "c"
        params = parse_params(symbol[:parameters_json])
        # Apple.discover の escape hatch: user が `params:` に `:cstring` /
        # `:uint32` 等 raw-ABI kind を明示した場合、 Swift overlay typing を経由せず
        # @_silgen_name 経由で C symbol を直叩きする。 これで Swift overlay 側の
        # CFAllocator? / UnsafePointer<CChar>! 等の bridged 型 mismatch を回避し、
        # README L8 commitment の static template path を維持する。
        if escape_hatch_params?(params)
          return emit_c_function_escape_hatch(framework: framework, symbol: symbol, glue_id: glue_id, params: params)
        end
        # Knowledge-Base classification fix-up: `void *` single-pointer
        # parameters carry an in-cookie (refCon) by Apple-API convention but
        # the importer occasionally tags nullable void* as is_out_param=true
        # (true out-pointers are double-pointers, `void **`). Force the flag
        # back to in so the call shape is not corrupted.
        params.each do |p|
          p[:is_out_param] = false if p[:kind] == "void_ptr_nilable"
        end
        ctx = { framework: framework, knowledge_cache: @kc, struct_visited: Set.new }
        marshallers = params.map.with_index { |p, i| Marshaller.for(p, i, ctx) }
        return nil if marshallers.any?(&:nil?)
        return nil if marshallers.any? { |m|
          m.param[:is_out_param] && m.out_handling.nil?
        }

        out_marshallers = marshallers.select { |m| m.param[:is_out_param] }

        in_loads = marshallers.reject { |m| m.param[:is_out_param] }
                              .map(&:in_load).compact

        call_args = marshallers.map { |m|
          m.param[:is_out_param] ? m.out_handling[:addr] : m.call_arg
        }.join(", ")

        call_expr = "#{symbol[:name]}(#{call_args})"
        if marshallers.any? { |m| m.is_a?(VariadicMarshaller) }
          call_expr = "withVaList(__cVarArgs) { __va in\n        return #{call_expr}\n    }"
        end

        body = []
        body.concat(in_loads)

        if out_marshallers.length == 1
          out = out_marshallers.first.out_handling
          body << out[:init]
          body << "let status = #{call_expr}"
          body << %(if status != 0 { rb_raise(rb_eRuntimeError, "OSStatus") })
          post = out_marshallers.first.out_post_call
          body << post if post
          body << "return #{out[:to_ruby]}"
        elsif out_marshallers.length >= 2
          # Multi-out: status check then build a Ruby Hash with one key per out-param.
          out_marshallers.each { |m| body << m.out_handling[:init] }
          body << "let status = #{call_expr}"
          body << %(if status != 0 { rb_raise(rb_eRuntimeError, "OSStatus") })
          body << "let multi_out_h = rb_hash_new()"
          out_marshallers.each do |m|
            post = m.out_post_call
            body << post if post
            body << "rb_hash_aset(multi_out_h, rb_str_new_cstr(\"#{m.param[:name]}\"), #{m.out_handling[:to_ruby]})"
          end
          body << "return multi_out_h"
        else
          ret_kind = effective_return_kind(symbol)
          if ret_kind == "cftype_ref_autoarc"
            # CF Create-rule auto-ARC. Route the +1-retained CF return value
            # through runtime_arc_box_cftype, which wraps in a BoxedCFType whose
            # deinit releases via ARC. User code never calls CFRelease. The Box
            # wrap happens inside the runtime dylib so glue Swift doesn't need
            # to import AppleSDKMacRuntime (LLM rule 3).
            body << "let raw = #{call_expr}"
            body << "let raw_uint = UInt(bitPattern: unsafeBitCast(raw, to: OpaquePointer.self))"
            body << "return rb_ull2inum(UInt64(runtime_arc_box_cftype(raw_uint)))"
          else
            body << "let result = #{call_expr}"
            if ret_kind == "status_int"
              body << %(if result != 0 { rb_raise(rb_eRuntimeError, "OSStatus") })
              body << "return Qnil"
            elsif ret_kind == "plain_int"
              # return_kind: :int override path: plain rb_ll2inum、OSStatus 検査なし。
              body << "return rb_ll2inum(Int64(result))"
            elsif ret_kind == "void"
              body << "return Qnil"
            else
              body << "return #{to_ruby_expr_by_kind(ret_kind, symbol[:signature], "result")}"
            end
          end
        end

        # Function name uses sanitized swift_identifier so canonical names
        # containing `.` / `:` / `(` / `)` (objc/swift kinds) emit valid Swift.
        # C-symbol names contain only [A-Za-z0-9_] so the gsub is a no-op for
        # the C-function path.
        swift_id = symbol[:name].to_s.gsub(/[^A-Za-z0-9_]/, "_")
        <<~SWIFT
          import #{framework}
          import Foundation

          #{HEADER}
          @c
          public func glue_#{glue_id}_#{swift_id}(
              _ argv: UnsafePointer<UInt>, _ argc: Int32
          ) -> UInt {
              #{body.join("\n    ")}
          }
        SWIFT
      end

      # ObjC class method emit. Apple.discover(class_method: "...", ...) で来た
      # synth record を Swift glue に。selector 末尾 colon を strip し、
      # `Klass.swiftMethod(args)` 形式の call site を emit。
      #
      # Swift 6 は多くの ObjC convenience constructors (`+stringWithUTF8String:`,
      # `+arrayWithObjects:count:` etc) を init に rename する (NS_SWIFT_NAME /
      # API_RENAMED)。selector が `<verb>With<Type>:` 形式の場合は
      # `Klass(label: arg)` init form を emit。
      def emit_objc_class_method(framework:, symbol:, glue_id:)
        klass = symbol[:objc_class].to_s
        # Swift 6 で ObjC NS-prefix が落とされている class を bridge:
        # NSBlockOperation → BlockOperation, NSOperationQueue → OperationQueue 等
        swift_klass = swift_bridged_class_name(klass)
        selector = symbol[:selector].to_s
        params = symbol[:params] || []
        # return_kind は Hash 形 (`{kind: :array_of_opaque_ref, ...}`) も
        # 受ける。 ObjcMarshalling.unpack_return_kind で kind_sym と meta を
        # 分離し、 ObjcMarshalling.return_lines 経由で raw 通す。
        return_kind = symbol[:return_kind] || :void
        swift_id = symbol[:name].to_s.gsub(/[^A-Za-z0-9_]/, "_")
        exported = "glue_#{glue_id}_#{swift_id}"

        in_loads = params.each_with_index.map { |k, i| ObjcMarshalling.in_load(k, i) }
        call_expr = swift_call_for_class_method(swift_klass, selector, params, framework: framework)

        body = in_loads + ["let raw = #{call_expr}"] + ObjcMarshalling.return_lines(return_kind, "raw")

        <<~SWIFT
          import #{framework}
          import Foundation

          #{HEADER}
          @c
          public func #{exported}(
              _ argv: UnsafePointer<UInt>, _ argc: Int32
          ) -> UInt {
              #{body.join("\n    ")}
          }
        SWIFT
      end

      # ObjC instance method emit. `selector:` で来た synth record。
      # argv[0] = receiver pointer、argv[1..] が user 引数。 selector が
      # `init*` 始まりの場合は Swift init form (no receiver) に分岐し、
      # `Klass(label: arg)` を emit する。
      def emit_objc_instance_method(framework:, symbol:, glue_id:)
        klass = symbol[:objc_class].to_s
        # Swift 6 NS-prefix bridge (NSOperationQueue → OperationQueue 等)
        swift_klass = swift_bridged_class_name(klass)
        selector = symbol[:selector].to_s
        params = symbol[:params] || []
        # return_kind Hash 形対応。
        return_kind = symbol[:return_kind] || :void
        return_kind_sym = ObjcMarshalling.unpack_return_kind(return_kind)[0]
        swift_id = symbol[:name].to_s.gsub(/[^A-Za-z0-9_]/, "_")
        exported = "glue_#{glue_id}_#{swift_id}"

        # selector 末尾 `:error:` (multi-segment) と `<Word>Error:`
        # (single-segment、 AVAudioEngine.startAndReturnError: 等) は Swift
        # throws bridge に変換。 ObjC `- (BOOL)method:(...)error:(NSError **)err`
        # / `- (BOOL)methodAndReturnError:(NSError **)err` → Swift
        # `func method(...) throws` / `func method() throws`。 emit は do/catch で
        # 包み、 success → Qtrue、 throw → Qfalse。 user 側 params 配列に
        # error_out は含めない。
        throws_bridge = selector.end_with?(":error:") || selector.match?(/(?:AndReturn|Returning)Error:\z/)
        effective_selector =
          if throws_bridge
            selector.sub(/(?::error:|(?:AndReturn|Returning)Error:)\z/, "")
          else
            selector
          end

        body =
          if selector.start_with?("init")
            # Init form: argv 0..N-1 が引数。receiver なし。
            in_loads = params.each_with_index.map { |k, i| ObjcMarshalling.in_load(k, i) }
            call_expr = swift_init_call(swift_klass, selector, params)
            in_loads + ["let raw = #{call_expr}"] + ObjcMarshalling.return_lines(return_kind, "raw")
          else
            # Instance method: argv[0] = receiver, argv[1..] が引数。
            receiver_load = <<~SWIFT.chomp
              let receiver = unsafeBitCast(
                  OpaquePointer(bitPattern: UInt(rb_num2ull(argv[0])))!,
                  to: #{swift_klass}.self
              )
            SWIFT
            in_loads = params.each_with_index.map { |k, i| ObjcMarshalling.in_load(k, i, argv_offset: 1) }
            call_expr = swift_call_for_instance_method(effective_selector, params)
            if throws_bridge
              # try call を do/catch で包む。 :bool return は success → Qtrue /
              # throw → Qfalse 固定。 他 return kind は将来実装。
              [receiver_load] + in_loads + [
                "do {",
                "    try #{call_expr}",
                "    return Qtrue",
                "} catch {",
                "    return Qfalse",
                "}"
              ]
            else
              # Zero-arg + non-void return は ObjC property bridge form
              # (parens なし)。 NSData.length / NSArray.count 等の property は
              # Swift で `obj.length` 形式 (method call は compile error)。
              # void return は引き続き method call form 維持 (resume() 等)。
              if params.empty? && return_kind_sym != :void
                call_expr = call_expr.sub(/\(\s*\)\z/, "")
              end
              # void return の call を `let raw =` に bind すると Swift 6 で
              # "constant 'raw' inferred to have type 'Void'" warning。 void は
              # 単独 statement で emit、 return_lines (`return Qnil`) を続ける。
              call_statement = return_kind_sym == :void ? call_expr : "let raw = #{call_expr}"
              [receiver_load] + in_loads + [call_statement] + ObjcMarshalling.return_lines(return_kind, "raw")
            end
          end

        <<~SWIFT
          import #{framework}
          import Foundation

          #{HEADER}
          @c
          public func #{exported}(
              _ argv: UnsafePointer<UInt>, _ argc: Int32
          ) -> UInt {
              #{body.join("\n    ")}
          }
        SWIFT
      end

      # Swift initializer emit. Apple.discover(swift_initializer: "init(string:)",
      # ...) で来た synth record を `guard let v = Klass(label: arg) else { return
      # Qnil }` shape の Swift glue に。 failable init の nil branch を Qnil で
      # 握りつぶす。
      def emit_swift_init(framework:, symbol:, glue_id:)
        klass = symbol[:swift_class].to_s
        # Swift 6 で Foundation ObjC class の NS-prefix が落ちる
        # (NSOperationQueue → OperationQueue, NSBlockOperation → BlockOperation
        # 等)。emit 側で strip して bridged Swift class name を使う。
        swift_klass = swift_bridged_class_name(klass)
        initializer = symbol[:swift_initializer].to_s
        params = symbol[:params] || []
        return_kind = (symbol[:return_kind] || :opaque_ref).to_sym
        swift_id = symbol[:name].to_s.gsub(/[^A-Za-z0-9_]/, "_")
        exported = "glue_#{glue_id}_#{swift_id}"

        labels = kb_labels(framework, symbol[:name]) || swift_init_labels(initializer)
        in_loads = params.each_with_index.map { |k, i| ObjcMarshalling.in_load(k, i) }
        call_expr =
          if labels.empty?
            "#{swift_klass}()"
          else
            args = params.each_index.map { |i| "arg#{i}" }
            "#{swift_klass}(" + labels.zip(args).map { |l, a| "#{l}: #{a}" }.join(", ") + ")"
          end

        # No-arg init は Apple SDK convention で non-failable と仮定。
        # 引数つき init の failability は initializer 文字列内の `?` で
        # 判定: `init?(label:)` (with ?) → failable / `init(label:)` (no ?) →
        # non-failable。 Apple SDK の majority は non-failable のため default は
        # `let v = ...`、 user が `swift_initializer: "init?(string:)"` のように
        # `?` を含めて指定したときのみ `guard let v = ... else { Qnil }`。
        # throws init (`init(...) throws`) は `try?` で wrap、 失敗時 Qnil。
        # user は `swift_initializer: "init(forReading:) throws"` と書くと
        # この path に乗る (AVAudioFile / AVAudioRecorder 等)。
        failable = kb_flag(framework, symbol[:name], :is_failable) { initializer.to_s.include?("?") }
        throwing = kb_flag(framework, symbol[:name], :is_throws) { initializer.to_s.include?("throws") }
        init_binding =
          if throwing
            "guard let v = try? #{call_expr} else { return Qnil }"
          elsif labels.empty? || !failable
            "let v = #{call_expr}"
          else
            "guard let v = #{call_expr} else { return Qnil }"
          end
        body = in_loads + [init_binding, *swift_init_return_lines(return_kind, "v")]

        <<~SWIFT
          import #{framework}
          import Foundation

          #{HEADER}
          @c
          public func #{exported}(
              _ argv: UnsafePointer<UInt>, _ argc: Int32
          ) -> UInt {
              #{body.join("\n    ")}
          }
        SWIFT
      end

      # Swift function emit. 同期 / async 両対応。 symbol[:async] = true の場合は
      # DispatchSemaphore + Task skeleton (E1 worked example) を emit して
      # ValidationGates.async_shape を通過する。 symbol[:swift_class] があれば
      # static method form (`Klass.func(args)`)、 なければ top-level (`func(args)`)。
      def emit_swift_func(framework:, symbol:, glue_id:)
        klass = symbol[:swift_class].to_s
        func = symbol[:swift_func].to_s
        params = symbol[:params] || []
        return_kind = (symbol[:return_kind] || :void).to_sym
        type_args = symbol[:type_args]
        is_async = kb_flag(framework, symbol[:name], :is_async) { symbol[:async] == true }
        swift_id = symbol[:name].to_s.gsub(/[^A-Za-z0-9_]/, "_")
        exported = "glue_#{glue_id}_#{swift_id}"

        in_loads = params.each_with_index.map { |k, i| ObjcMarshalling.in_load(k, i) }
        args_str = params.each_index.map { |i| "arg#{i}" }.join(", ")
        type_args_str = type_args ? "<#{Array(type_args).join(', ')}>" : ""
        callee = klass.empty? ? "#{func}#{type_args_str}" : "#{klass}.#{func}#{type_args_str}"
        plain_call = "#{callee}(#{args_str})"

        body =
          if is_async
            swift_t = swift_type_for_return(return_kind)
            [
              *in_loads,
              "let sema = DispatchSemaphore(value: 0)",
              "var result: #{swift_t}?",
              "var captured: Error?",
              "Task {",
              "    do { result = try await #{plain_call} }",
              "    catch { captured = error }",
              "    sema.signal()",
              "}",
              "sema.wait()",
              %(if let e = captured { rb_raise(rb_eRuntimeError, "\\(e)") }),
              *swift_async_return_lines(return_kind, "result!")
            ]
          else
            in_loads + ["let raw = #{plain_call}"] + swift_init_return_lines(return_kind, "raw")
          end

        <<~SWIFT
          import #{framework}
          import Foundation

          #{HEADER}
          @c
          public func #{exported}(
              _ argv: UnsafePointer<UInt>, _ argc: Int32
          ) -> UInt {
              #{body.join("\n    ")}
          }
        SWIFT
      end

      # async result の Swift 型 (var result: T? の T)。
      def swift_type_for_return(return_kind)
        case return_kind.to_sym
        when :int   then "Int64"
        when :bool  then "Bool"
        when :float then "Double"
        when :opaque_ref, :cftype_ref then "AnyObject"
        when :void  then "Void"
        else "AnyObject"
        end
      end

      # async path 後の Ruby 値返し (result! はすでに非 nil 保証されている前提
      # — captured nil + result nil は async が成功扱いで result 未設定なので
      # rb_raise 後に届く Qnil ではなく ぐる Type panic として nil 化する)。
      def swift_async_return_lines(return_kind, var)
        case return_kind.to_sym
        when :void
          ["return Qnil"]
        else
          swift_init_return_lines(return_kind, var)
        end
      end

      # Swift property emit. static / class-level property access
      # (`Klass.property`)。 NSURLSession.shared, ProcessInfo.processInfo etc.
      # 戻り値は return_kind に従って marshal。
      def emit_swift_property(framework:, symbol:, glue_id:)
        # Swift 6 の NS-prefix rename (NSURLSession → URLSession 等) に対応する
        # ため klass を bridged 名に変換。 ObjC 名がそのまま Swift type として
        # 有効な場合 (NSError 等) は変化なし。
        klass = swift_bridged_class_name(symbol[:swift_class].to_s)
        prop = symbol[:swift_property].to_s
        # return_kind は :symbol または Hash 形 (`{kind:, type:, nilable:}`)
        # の両対応。 swift_init_return_lines が unwrap する。
        return_kind = symbol[:return_kind] || :opaque_ref
        # instance: true で argv[0] を receiver にとる instance property 経路。
        # default false は class static property。
        instance = symbol[:instance] == true
        swift_id = symbol[:name].to_s.gsub(/[^A-Za-z0-9_]/, "_")
        exported = "glue_#{glue_id}_#{swift_id}"

        body =
          if instance
            receiver_load = <<~SWIFT.chomp
              let receiver = unsafeBitCast(
                  OpaquePointer(bitPattern: UInt(rb_num2ull(argv[0])))!,
                  to: #{klass}.self
              )
            SWIFT
            [receiver_load, "let raw = receiver.#{prop}"] +
              swift_init_return_lines(return_kind, "raw")
          else
            ["let raw = #{klass}.#{prop}"] +
              swift_init_return_lines(return_kind, "raw")
          end

        <<~SWIFT
          import #{framework}
          import Foundation

          #{HEADER}
          @c
          public func #{exported}(
              _ argv: UnsafePointer<UInt>, _ argc: Int32
          ) -> UInt {
              #{body.join("\n    ")}
          }
        SWIFT
      end

      # `init(label1:label2:)` から ["label1", "label2"] を抜き出す。
      # `init()` → []。
      def swift_init_labels(initializer)
        # `init?(...)` (failable) と `init(...) throws` の両方受ける regex。
        m = initializer.match(/\Ainit\??\((.*)\)(?:\s+throws)?\z/)
        return [] unless m
        m[1].split(":", -1).reject(&:empty?)
      end

      # Preposition-aware verb-label split for ObjC→Swift bridge.
      # Returns [verb, label] when sole matches `<verb><Preposition><Type>` for
      # any preposition in OBJC_BRIDGE_PREPOSITIONS, else nil.
      OBJC_BRIDGE_PREPOSITIONS = %w[For By Using From At In To On].freeze
      def split_preposition_verb(sole)
        OBJC_BRIDGE_PREPOSITIONS.each do |prep|
          if (m = sole.match(/\A([a-z][a-zA-Z0-9]*?)#{prep}([A-Z]\w*)\z/))
            verb = m[1]
            type_part = m[2]
            label = AppleSDKMac::SelectorBridge.lower_first_camel(prep + type_part)
            return [verb, label]
          end
        end
        nil
      end

      # Swift 6 ObjC class bridge: NS-prefix 落とし。
      # NSOperationQueue → OperationQueue / NSBlockOperation → BlockOperation /
      # NSURL → URL 等。Apple Foundation の標準 bridge rule。
      # `NS<lowercase>` は対象外、 大文字で始まる NS<UpperCase> パターンのみ strip。
      #
      # NS-strip 対象外。 これらの class は Swift bridge で value type (struct)
      # に rename されるが API divergent (NSData.length vs Data.count、
      # NSString.UTF8String vs String 系等) なので、 user 明示 discover (klass:
      # :NSData 等) の semantics は ObjC class form を保つ必要がある。
      NS_STRIP_PRESERVE_LIST = %w[NSData NSString NSArray NSDictionary NSSet
                                  NSMutableArray NSMutableDictionary NSMutableSet
                                  NSMutableString NSError].freeze

      def swift_bridged_class_name(klass)
        return klass.to_s if NS_STRIP_PRESERVE_LIST.include?(klass.to_s)
        klass.to_s.sub(/\ANS([A-Z])/, '\1')
      end

      # swift_init の return marshaling。opaque_ref を passRetained して
      # Ruby Integer へ。それ以外は基本 marshaling。
      # return_kind が Hash 形 (`{kind:, type:, nilable:}`) なら kind 抽出
      # して dispatch、 :array_of_opaque_ref など typed array 戻り値を marshal。
      def swift_init_return_lines(return_kind, var)
        kind_sym, _meta = ObjcMarshalling.unpack_return_kind(return_kind)
        case kind_sym
        when :opaque_ref
          [
            "let p = Unmanaged.passRetained(#{var} as AnyObject).toOpaque()",
            "return rb_ull2inum(UInt64(UInt(bitPattern: p)))"
          ]
        else
          ObjcMarshalling.return_lines(return_kind, var)
        end
      end

      # Instance method selector を Swift bridged call form に変換。
      # single-segment: receiver.<method>(arg0, arg1, ...) (label なし)
      # multi-segment: receiver.<method>(<label>: arg0, <label>: arg1, ...)
      # 第1 segment が `<verb>With<Type>` shape なら Apple bridging に従い
      # method = `<verb>`, first_label = "with" (Type は label に含めない)。
      def swift_call_for_instance_method(selector, params, receiver_var: "receiver")
        parts = selector.split(":", -1).reject(&:empty?)
        args = params.each_index.map { |i| "arg#{i}" }
        if parts.size == 1
          "#{receiver_var}.#{parts[0]}(#{args.join(', ')})"
        else
          if (m = parts[0].match(/\A(\w+?)With([A-Z]\w+)\z/))
            method_name = m[1]
            labels = ["with"] + parts[1..]
          else
            method_name = parts[0]
            # Apple SDK ObjC→Swift bridge convention: multi-segment
            # selector の first arg は label 無し (`_:`)、第2..n 引数のラベル
            # は parts[1..] で対応する。`addOperations:waitUntilFinished:` →
            # `addOperations(_ ops:, waitUntilFinished wait:)` 型。
            labels = [nil] + parts[1..]
          end
          label_args = labels.zip(args).map { |l, a|
            l.nil? ? a.to_s : "#{l}: #{a}"
          }.join(", ")
          "#{receiver_var}.#{method_name}(#{label_args})"
        end
      end

      # init multi-segment selector (`initWithCGImage:options:`) を Swift
      # bridged init form (`Klass(cgImage: arg0, options: arg1)`) に変換。
      def swift_init_call(klass, selector, params)
        parts = selector.split(":", -1).reject(&:empty?)
        # parts[0] starts with "init" — drop "init" + optional bridge prefix
        head = parts[0].sub(/\Ainit/, "").sub(/\A(With|From|By|Using|For)/, "")
        head = AppleSDKMac::SelectorBridge.lower_first_camel(head)
        labels = head.empty? ? parts[1..] : ([head] + parts[1..])
        if labels.empty?
          # `init` selector with no labels (rare).
          "#{klass}()"
        else
          args = params.each_index.map { |i| "arg#{i}" }
          label_args = labels.zip(args).map { |l, a| "#{l}: #{a}" }.join(", ")
          "#{klass}(#{label_args})"
        end
      end

      # Class method を Swift call expression に変換。Swift 6 は
      # `+<verb>With<Type>:` shape の convenience constructors を init に rename
      # (e.g. NSString.stringWithUTF8String → NSString.init(utf8String:))。
      # この shape の selector は init form を emit する。それ以外は class method
      # form (`Klass.swiftMethod(args)`) を維持。
      def swift_call_for_class_method(klass, selector, params, framework: nil)
        # Try Knowledge Base swift_imported_name + manual overrides first.
        # Heuristic remains the fallback for selectors not yet covered by
        # the Swift overlay importer (e.g. selectors from frameworks the
        # importer skipped due to generic / async / where clauses).
        if (kb_or_override = SwiftBridgeName.resolve(
              framework: framework, klass: klass,
              selector: selector, params: params, kc: @kc,
            ))
          return kb_or_override
        end

        parts = selector.split(":", -1).reject(&:empty?)
        if parts.size == 1
          sole = parts[0]
          # Apple ObjC→Swift bridge convention:
          # 1. `<verb>With<Type>:` (init bridge) → `<klass>(<typeAsLabel>: arg0)`
          #    label は lowerCamel(<Type>)。e.g. stringWithUTF8String →
          #    NSString(utf8String: arg0).
          # 2. `<verb><Preposition><Type>:` (For/By/Using/From/At/In/To/On)
          #    (class method bridge) → `<klass>.<verb>(<prepositionWithType>: arg0)`
          #    label は lowerCamel(<Preposition><Type>)。e.g. sleepForTimeInterval
          #    → Thread.sleep(forTimeInterval: arg0).
          if (m = sole.match(/\A([A-Za-z][a-zA-Z0-9]*?)With([A-Z]\w*)\z/))
            label = AppleSDKMac::SelectorBridge.lower_first_camel(m[2])
            # utf8String / cString init bridges は raw UnsafePointer<CChar>
            # を expect (deprecated だが Swift 6 でも残存)。 :string in_load の
            # Swift String 化に伴い、 これらの label の場合は cstr 補助名を渡す。
            arg0_expr = %w[utf8String cString].include?(label) ? "arg0_cstr" : "arg0"
            "#{klass}(#{label}: #{arg0_expr})"
          elsif (verb_label = split_preposition_verb(sole))
            verb, label = verb_label
            "#{klass}.#{verb}(#{label}: arg0)"
          else
            args_str = params.each_index.map { |i| "arg#{i}" }.join(", ")
            "#{klass}.#{sole}(#{args_str})"
          end
        else
          # multi-segment class method: 最初の segment を init label の頭に
          # 持ち、残りを segment label に対応させる convenience init form。
          head = parts[0].sub(/\A[a-z]+With/, "")
          head = AppleSDKMac::SelectorBridge.lower_first_camel(head)
          labels = head.empty? ? parts[1..] : ([head] + parts[1..])
          args = params.each_index.map { |i| "arg#{i}" }
          label_args = labels.zip(args).map { |l, a| "#{l}: #{a}" }.join(", ")
          "#{klass}(#{label_args})"
        end
      end


      # Escape-hatch C function emit. Activates when Apple.discover の
      # `params:` に `:cstring` / `:uint32` を含む raw-ABI shape が来たとき、
      # Swift overlay 経由ではなく @_silgen_name 経由で C symbol を直接呼ぶ。
      # README L8 commitment 「any public Apple framework API」 を escape hatch
      # 経由でも static template path で完結させる目的。
      ESCAPE_HATCH_KINDS = %w[opaque_ref cstring uint32 int bool float].freeze

      def escape_hatch_params?(params)
        return false if params.empty?
        params.all? { |p|
          ESCAPE_HATCH_KINDS.include?(p[:kind].to_s) && !p[:is_out_param]
        } && params.any? { |p| %w[cstring uint32].include?(p[:kind].to_s) }
      end

      # @_silgen_name shadow declaration の Swift 引数型 (raw C ABI) を kind から決める。
      def escape_hatch_swift_arg_type(kind)
        case kind.to_s
        when "cstring"    then "UnsafePointer<CChar>?"
        when "uint32"     then "UInt32"
        when "int"        then "Int64"
        when "bool"       then "Bool"
        when "float"      then "Double"
        when "opaque_ref" then "UnsafeRawPointer?"
        else                   "UnsafeRawPointer?"
        end
      end

      # argv[i] → Swift binding の Swift 1 行を kind から決める。 Qnil 経路は
      # rb_num2ull が raise するため pre-guard でゼロ／nil 化。
      def escape_hatch_in_load(kind, index)
        case kind.to_s
        when "cstring"
          # rb_string_value_cstr は Ruby String の内部 buffer pointer を返す。
          # Qnil の場合は nil を渡したい (CF API は概ね NULL 受け入れ可)。
          <<~SWIFT.chomp
            var v#{index} = argv[#{index}]
                let arg#{index}: UnsafePointer<CChar>? = (argv[#{index}] == Qnil) ? nil : rb_string_value_cstr(&v#{index})
          SWIFT
        when "uint32"
          "let arg#{index}: UInt32 = UInt32(rb_num2ull(argv[#{index}]))"
        when "int"
          "let arg#{index}: Int64 = rb_num2ll(argv[#{index}])"
        when "bool"
          "let arg#{index}: Bool = (argv[#{index}] != Qfalse && argv[#{index}] != Qnil)"
        when "float"
          "let arg#{index}: Double = rb_num2dbl(argv[#{index}])"
        when "opaque_ref"
          # Qnil → nil pointer 化、 raw integer → UnsafeRawPointer。
          # CFStringCreateWithCString の CFAllocatorRef alloc 引数等、
          # NULL 許容な C ABI に nil を渡す経路。
          <<~SWIFT.chomp
            let arg#{index}_raw: UInt = (argv[#{index}] == Qnil) ? 0 : UInt(rb_num2ull(argv[#{index}]))
                let arg#{index}: UnsafeRawPointer? = (arg#{index}_raw == 0) ? nil : UnsafeRawPointer(bitPattern: arg#{index}_raw)
          SWIFT
        else
          raise ArgumentError, "escape_hatch_in_load: unsupported kind #{kind.inspect}"
        end
      end

      def emit_c_function_escape_hatch(framework:, symbol:, glue_id:, params:)
        c_symbol = symbol[:name].to_s
        return_kind_sym = (symbol[:return_kind] || :void).to_sym

        shadow_name = "__escape_#{c_symbol}"
        arg_types = params.map { |p| escape_hatch_swift_arg_type(p[:kind]) }
        ret_type =
          case return_kind_sym
          when :opaque_ref, :cftype_ref then "UnsafeRawPointer?"
          when :int                     then "Int64"
          when :bool                    then "Bool"
          when :float                   then "Double"
          when :uint32                  then "UInt32"
          when :void                    then "Void"
          else "UnsafeRawPointer?"
          end

        shadow_decl = <<~SWIFT.chomp
          @_silgen_name("#{c_symbol}")
          func #{shadow_name}(#{arg_types.each_with_index.map { |t, i| "_ a#{i}: #{t}" }.join(', ')}) -> #{ret_type}
        SWIFT

        in_loads = params.each_with_index.map { |p, i| escape_hatch_in_load(p[:kind], i) }
        call_args = params.each_index.map { |i| "arg#{i}" }.join(", ")
        call_expr = "#{shadow_name}(#{call_args})"

        body = in_loads.dup
        case return_kind_sym
        when :opaque_ref, :cftype_ref
          # CF Create/Copy 命名規約に当てはまるなら autoarc box、 それ以外は raw。
          body << "let raw = #{call_expr}"
          body << "let raw_uint: UInt = raw.map { UInt(bitPattern: $0) } ?? 0"
          if cf_create_naming?(c_symbol)
            body << "return rb_ull2inum(UInt64(runtime_arc_box_cftype(raw_uint)))"
          else
            body << "return rb_ull2inum(UInt64(raw_uint))"
          end
        when :int
          body << "let raw = #{call_expr}"
          body << "return rb_ll2inum(raw)"
        when :uint32
          body << "let raw = #{call_expr}"
          body << "return rb_ull2inum(UInt64(raw))"
        when :bool
          body << "let raw = #{call_expr}"
          body << "return raw ? Qtrue : Qfalse"
        when :float
          body << "let raw = #{call_expr}"
          body << "return rb_float_new(raw)"
        when :void
          body << "_ = #{call_expr}"
          body << "return Qnil"
        else
          body << "let raw = #{call_expr}"
          body << "return rb_ull2inum(UInt64(UInt(bitPattern: raw)))"
        end

        swift_id = c_symbol.gsub(/[^A-Za-z0-9_]/, "_")
        <<~SWIFT
          import #{framework}
          import Foundation

          #{HEADER}
          #{shadow_decl}
          @c
          public func glue_#{glue_id}_#{swift_id}(
              _ argv: UnsafePointer<UInt>, _ argc: Int32
          ) -> UInt {
              #{body.join("\n    ")}
          }
        SWIFT
      end

      private

      def parse_params(json)
        return [] if json.nil? || json.empty?
        JSON.parse(json, symbolize_names: true)
      end

      # When Apple.discover passes an explicit return_kind override (e.g.
      # `int` for a status code that should not trigger OSStatus checking),
      # the signature regex is bypassed and the override drives marshaller
      # selection directly.
      RETURN_KIND_OVERRIDE_TO_TEMPLATE = {
        int: "plain_int", bool: "bool", float: "float", void: "void",
        string: "string", opaque_ref: "opaque_ref",
        cftype_ref: "cftype_ref", cftype_ref_autoarc: "cftype_ref_autoarc"
      }.freeze

      def effective_return_kind(symbol)
        if symbol[:return_kind] && (mapped = RETURN_KIND_OVERRIDE_TO_TEMPLATE[symbol[:return_kind].to_sym])
          return mapped
        end
        kind = return_kind(symbol[:signature])
        return kind unless kind == "cftype_ref"
        # Per CF ownership rules, any CF*Create* / CF*Copy* function returns
        # a +1-retained reference the caller must release — so it's auto-ARC
        # eligible. The naming-prefix heuristic is the canonical signal.
        return "cftype_ref_autoarc" if cf_create_naming?(symbol[:name])
        kind
      end

      def cf_create_naming?(name)
        name.to_s =~ /\A(?:CF|CG|CV|CT|CM|CL|IO|Sec|AX)\w*(?:Create|Copy)/
      end

      # Knowledge Base record から flag column を読む。 @kc が無い / Knowledge Base
      # miss / column が nil の場合は block の fallback (heuristic / signature 文字列
      # include?) を返す。 既存の Apple.discover escape hatch で synth record を
      # user 渡しする path を壊さない。
      def kb_flag(framework, symbol_name, column)
        return yield unless @kc
        rec = @kc.lookup_symbol(framework: framework, symbol: symbol_name)
        return yield unless rec
        v = rec[column]
        v.nil? ? yield : v
      end

      # Knowledge Base record の parameters_json から external_label 配列を取り出す。
      # external_label が無い / `_` underscore label / parameters_json 不在は nil
      # 返しで caller に文字列 split helper へ fallback してもらう。
      def kb_labels(framework, symbol_name)
        return nil unless @kc
        rec = @kc.lookup_symbol(framework: framework, symbol: symbol_name)
        return nil unless rec && rec[:parameters_json]
        parsed = JSON.parse(rec[:parameters_json])
        return nil unless parsed.is_a?(Array) && parsed.any?
        labels = parsed.map { |p| p.is_a?(Hash) && p["external_label"] }
        return nil if labels.any? { |l| l.nil? || l == "" || l == "_" }
        labels
      end

      def return_kind(signature)
        sig = signature.to_s.strip
        return "void"   if sig =~ /\A(?:void)\b/
        # NOTE: CFStringRef / NSString * are CF / ObjC opaque types, NOT
        # raw cstrings — passing them to rb_str_new_cstr is a type error.
        # Only the `char *` family is treated as a cstring return; CF/NS
        # text types fall through to cftype_ref / opaque_ref handling.
        return "string" if sig =~ /\A(?:char\s*\*|const\s+char\s*\*)/
        return "bool"   if sig =~ /\A(?:_Bool|Bool|BOOL)\b/
        return "float"  if sig =~ /\A(?:double|float|CGFloat|CFAbsoluteTime|CFTimeInterval|NSTimeInterval|TimeInterval)\b/
        if sig =~ /\A(?:OSStatus|kern_return_t|int|signed|unsigned|U?Int(?:8|16|32|64)?|SInt(?:8|16|32|64)?|long|short|uint(?:8|16|32|64)_t|int(?:8|16|32|64)_t)\b/
          return "status_int"
        end
        # Pointer-typed Refs (CF/CG/CV/CT/CM/CL/IO/Sec/AX). See cftype_ref Marshaller.
        return "cftype_ref" if sig =~ /\A(?:CF|CG|CV|CT|CM|CL|IO|Sec|AX)\w+Ref\b/
        return "opaque_ref" if sig =~ /\A\w+Ref\b/
        "unsupported"
      end

      def to_ruby_expr_by_kind(kind, signature, swift_var)
        case kind
        when "string"     then "rb_str_new_cstr(#{swift_var})"
        when "bool"       then "(#{swift_var} ? Qtrue : Qfalse)"
        when "float"      then "rb_float_new(#{swift_var})"
        when "cftype_ref"
          # Encode CF pointer as Ruby Integer via OpaquePointer raw bit-pattern.
          # User is responsible for CFRelease (no ARC bridging on this path).
          "rb_ull2inum(UInt64(UInt(bitPattern: unsafeBitCast(#{swift_var}, to: OpaquePointer.self))))"
        when "opaque_ref"
          if signature && signature.match?(/\A(?:UInt|uint)/)
            "rb_ull2inum(UInt64(#{swift_var}))"
          else
            "rb_ll2inum(Int64(#{swift_var}))"
          end
        else
          "rb_ll2inum(Int64(#{swift_var}))"
        end
      end
    end
  end
end
