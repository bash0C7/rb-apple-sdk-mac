# frozen_string_literal: true
require "json"
require "set"
require_relative "marshallers"

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
        # T42-T48 — kind dispatcher。Apple.discover の synth record で
        # objc/swift kinds が来たら専用 emitter に routing。C-function 経路は
        # 既存 path を維持。未対応 kind は nil で LLM fallback へ流す。
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
        # Phase 7 — KB-side classification fix-up. `void *` single-pointer
        # parameters carry an in-cookie (refCon) by Apple-API convention
        # but the knowledge importer occasionally tags nullable void*
        # as is_out_param=true (true out-pointers are double-pointers,
        # `void **`). Force the flag back to in so the call shape is
        # not corrupted (`MIDIPortConnectSource(port, source, )` etc.).
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
            # Phase 7 T4 — CF Create-rule auto-ARC. Route the +1-retained CF
            # return value through the runtime ARC pillar's
            # runtime_arc_box_cftype entry point, which wraps in a BoxedCFType
            # whose deinit releases via ARC. User code never calls CFRelease.
            # The Box wrap happens inside the runtime dylib so glue Swift
            # doesn't need to import AppleSDKMacRuntime (LLM rule 3).
            body << "let raw = #{call_expr}"
            body << "let raw_uint = UInt(bitPattern: unsafeBitCast(raw, to: OpaquePointer.self))"
            body << "return rb_ull2inum(UInt64(runtime_arc_box_cftype(raw_uint)))"
          else
            body << "let result = #{call_expr}"
            if ret_kind == "status_int"
              body << %(if result != 0 { rb_raise(rb_eRuntimeError, "OSStatus") })
              body << "return Qnil"
            elsif ret_kind == "plain_int"
              # T50 — return_kind: :int override path: plain rb_ll2inum、OSStatus 検査なし。
              body << "return rb_ll2inum(Int64(result))"
            elsif ret_kind == "void"
              body << "return Qnil"
            else
              body << "return #{to_ruby_expr_by_kind(ret_kind, symbol[:signature], "result")}"
            end
          end
        end

        # T40 — function name uses sanitized swift_identifier so canonical
        # names containing `.` / `:` / `(` / `)` (objc/swift kinds) emit valid
        # Swift. C-symbol names contain only [A-Za-z0-9_] so the gsub is a
        # no-op for the existing template path; the call here is forward-
        # compatible with kind-dispatched emitters in T42-T48.
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

      # T42 — ObjC class method emit (spec §3.4.1)。
      # Apple.discover(class_method: "stringWithUTF8String:", ...) で来た synth
      # record を Swift glue に。selector 末尾 colon を strip し、
      # `Klass.swiftMethod(args)` 形式の call site を emit。
      #
      # T43 修正: Swift 6 は多くの ObjC convenience constructors
      # (`+stringWithUTF8String:`, `+arrayWithObjects:count:` etc) を init に
      # rename する (NS_SWIFT_NAME / API_RENAMED)。selector が `<verb>With<Type>:`
      # 形式の場合は `Klass(label: arg)` init form を emit。
      def emit_objc_class_method(framework:, symbol:, glue_id:)
        klass = symbol[:objc_class].to_s
        # T52e — Swift 6 で ObjC NS-prefix が落とされている class を bridge:
        # NSBlockOperation → BlockOperation, NSOperationQueue → OperationQueue 等
        swift_klass = swift_bridged_class_name(klass)
        selector = symbol[:selector].to_s
        params = symbol[:params] || []
        # T54o — return_kind は Hash 形 (`{kind: :array_of_opaque_ref, ...}`) も
        # 受ける。 unpack_return_kind で kind_sym と meta を分離し、 marshal は
        # objc_return_lines 経由で raw 通す。
        return_kind = symbol[:return_kind] || :void
        swift_id = symbol[:name].to_s.gsub(/[^A-Za-z0-9_]/, "_")
        exported = "glue_#{glue_id}_#{swift_id}"

        in_loads = params.each_with_index.map { |k, i| objc_in_load(k, i) }
        call_expr = swift_call_for_class_method(swift_klass, selector, params)

        body = in_loads + ["let raw = #{call_expr}"] + objc_return_lines(return_kind, "raw")

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

      # T44 — ObjC instance method emit (spec §3.4.2)。
      # `selector:` で来た synth record。argv[0] = receiver pointer、argv[1..]
      # が user 引数。selector が `init*` 始まりの場合は Swift init form
      # (no receiver) に分岐し、`Klass(label: arg)` を emit する。
      def emit_objc_instance_method(framework:, symbol:, glue_id:)
        klass = symbol[:objc_class].to_s
        # T52e — Swift 6 NS-prefix bridge (NSOperationQueue → OperationQueue 等)
        swift_klass = swift_bridged_class_name(klass)
        selector = symbol[:selector].to_s
        params = symbol[:params] || []
        # T54o — return_kind Hash 形対応。
        return_kind = symbol[:return_kind] || :void
        return_kind_sym = unpack_return_kind(return_kind)[0]
        swift_id = symbol[:name].to_s.gsub(/[^A-Za-z0-9_]/, "_")
        exported = "glue_#{glue_id}_#{swift_id}"

        # T54m — selector 末尾 `:error:` は Swift throws bridge に変換。
        # ObjC `- (BOOL)method:(...)error:(NSError **)err` → Swift
        # `func method(...) throws`。 emit は do/catch で包み、 success →
        # Qtrue、 throw → Qfalse。 user 側 params 配列に error_out は含めない。
        throws_bridge = selector.end_with?(":error:")
        effective_selector = throws_bridge ? selector.sub(/:error:\z/, ":") : selector

        body =
          if selector.start_with?("init")
            # Init form: argv 0..N-1 が引数。receiver なし。
            in_loads = params.each_with_index.map { |k, i| objc_in_load(k, i) }
            call_expr = swift_init_call(swift_klass, selector, params)
            in_loads + ["let raw = #{call_expr}"] + objc_return_lines(return_kind, "raw")
          else
            # Instance method: argv[0] = receiver, argv[1..] が引数。
            receiver_load = <<~SWIFT.chomp
              let receiver = unsafeBitCast(
                  OpaquePointer(bitPattern: UInt(rb_num2ull(argv[0])))!,
                  to: #{swift_klass}.self
              )
            SWIFT
            in_loads = params.each_with_index.map { |k, i| objc_in_load(k, i, argv_offset: 1) }
            call_expr = swift_call_for_instance_method(effective_selector, params)
            if throws_bridge
              # T54m — try call を do/catch で包む。 :bool return は success
              # → Qtrue / throw → Qfalse 固定。 他 return kind は将来実装。
              [receiver_load] + in_loads + [
                "do {",
                "    try #{call_expr}",
                "    return Qtrue",
                "} catch {",
                "    return Qfalse",
                "}"
              ]
            else
              # T53g — zero-arg + non-void return は ObjC property bridge form
              # (parens なし)。 NSData.length / NSArray.count 等の property は
              # Swift で `obj.length` 形式 (method call は compile error)。
              # void return は引き続き method call form 維持 (resume() 等)。
              if params.empty? && return_kind_sym != :void
                call_expr = call_expr.sub(/\(\s*\)\z/, "")
              end
              [receiver_load] + in_loads + ["let raw = #{call_expr}"] + objc_return_lines(return_kind, "raw")
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

      # T45 — Swift initializer emit (spec §3.4.3)。
      # Apple.discover(swift_initializer: "init(string:)", ...) で来た synth
      # record を `guard let v = Klass(label: arg) else { return Qnil }` shape
      # の Swift glue に。failable init の nil branch を Qnil で握りつぶす。
      def emit_swift_init(framework:, symbol:, glue_id:)
        klass = symbol[:swift_class].to_s
        # T52c — Swift 6 で Foundation ObjC class の NS-prefix が落ちる
        # (NSOperationQueue → OperationQueue, NSBlockOperation → BlockOperation
        # 等)。emit 側で strip して bridged Swift class name を使う。
        swift_klass = swift_bridged_class_name(klass)
        initializer = symbol[:swift_initializer].to_s
        params = symbol[:params] || []
        return_kind = (symbol[:return_kind] || :opaque_ref).to_sym
        swift_id = symbol[:name].to_s.gsub(/[^A-Za-z0-9_]/, "_")
        exported = "glue_#{glue_id}_#{swift_id}"

        labels = swift_init_labels(initializer)
        in_loads = params.each_with_index.map { |k, i| objc_in_load(k, i) }
        call_expr =
          if labels.empty?
            "#{swift_klass}()"
          else
            args = params.each_index.map { |i| "arg#{i}" }
            "#{swift_klass}(" + labels.zip(args).map { |l, a| "#{l}: #{a}" }.join(", ") + ")"
          end

        # T52c — no-arg init は Apple SDK convention で non-failable と仮定。
        # T54t — 引数つき init の failability は initializer 文字列内の `?` で
        # 判定: `init?(label:)` (with ?) → failable / `init(label:)` (no ?) →
        # non-failable。 Apple SDK の majority は non-failable のため default は
        # `let v = ...`、 user が `swift_initializer: "init?(string:)"` のように
        # `?` を含めて指定したときのみ `guard let v = ... else { Qnil }`。
        failable = initializer.to_s.include?("?")
        init_binding =
          if labels.empty? || !failable
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

      # T47 — Swift function emit (spec §3.4.5)。同期 / async 両対応。
      # symbol[:async] = true の場合は spec §3.6 の DispatchSemaphore + Task
      # skeleton (E1 worked example) を emit。ValidationGates.async_shape を
      # 通過する。symbol[:swift_class] があれば static method form
      # (`Klass.func(args)`)、なければ top-level (`func(args)`)。
      def emit_swift_func(framework:, symbol:, glue_id:)
        klass = symbol[:swift_class].to_s
        func = symbol[:swift_func].to_s
        params = symbol[:params] || []
        return_kind = (symbol[:return_kind] || :void).to_sym
        type_args = symbol[:type_args]
        is_async = symbol[:async] == true
        swift_id = symbol[:name].to_s.gsub(/[^A-Za-z0-9_]/, "_")
        exported = "glue_#{glue_id}_#{swift_id}"

        in_loads = params.each_with_index.map { |k, i| objc_in_load(k, i) }
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

      # T46 — Swift property emit (spec §3.4.4 base shape)。
      # static / class-level property access (`Klass.property`)。NSURLSession.shared,
      # ProcessInfo.processInfo etc. instance property は将来対応 (receiver-form)。
      # 戻り値は return_kind に従って marshal。
      def emit_swift_property(framework:, symbol:, glue_id:)
        # T53d — Swift 6 の NS-prefix rename (NSURLSession → URLSession 等) に
        # 対応するため klass を bridged 名に変換。 ObjC 名がそのまま Swift type
        # として有効な場合 (NSError 等) は変化なし。
        klass = swift_bridged_class_name(symbol[:swift_class].to_s)
        prop = symbol[:swift_property].to_s
        # T54n — return_kind は :symbol または Hash 形 (`{kind:, type:, nilable:}`)
        # の両対応。 swift_init_return_lines が unwrap する。
        return_kind = symbol[:return_kind] || :opaque_ref
        # T54u — instance: true で argv[0] を receiver にとる instance property
        # 経路。 default false は class static property (T53d 互換)。
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
        # T54t — `init?(...)` (failable) も受ける regex に拡張。
        m = initializer.match(/\Ainit\??\((.*)\)\z/)
        return [] unless m
        m[1].split(":", -1).reject(&:empty?)
      end

      # T52g — Preposition-aware verb-label split for ObjC→Swift bridge.
      # Returns [verb, label] when sole matches `<verb><Preposition><Type>` for
      # any preposition in OBJC_BRIDGE_PREPOSITIONS, else nil.
      OBJC_BRIDGE_PREPOSITIONS = %w[For By Using From At In To On].freeze
      def split_preposition_verb(sole)
        OBJC_BRIDGE_PREPOSITIONS.each do |prep|
          if (m = sole.match(/\A([a-z][a-zA-Z0-9]*?)#{prep}([A-Z]\w*)\z/))
            verb = m[1]
            type_part = m[2]
            label = lower_first_camel_local(prep + type_part)
            return [verb, label]
          end
        end
        nil
      end

      # T52c — Swift 6 ObjC class bridge: NS-prefix 落とし。
      # NSOperationQueue → OperationQueue / NSBlockOperation → BlockOperation /
      # NSURL → URL 等。Apple Foundation の標準 bridge rule。
      # 例外 (NSError, NSObject 等) は v1.0 範囲外、必要時に skip リストを
      # 追加する。`NS<lowercase>` (NSObject ではなく ns_object_t 系) は
      # 大文字で始まる NS<UpperCase> パターンのみ strip。
      # T53f — NS-strip 対象外。 これらの class は Swift bridge で value type
      # (struct) に rename されるが API divergent (NSData.length vs Data.count、
      # NSString.UTF8String vs String 系等) なので、 user 明示 discover (klass:
      # :NSData 等) の semantics は ObjC class form を保つ必要がある。
      NS_STRIP_PRESERVE_LIST = %w[NSData NSString NSArray NSDictionary NSSet
                                  NSMutableArray NSMutableDictionary NSMutableSet
                                  NSMutableString NSError].freeze

      # T53i — Swift value-type ↔ NSObject class bridge map。 Hash 形
      # `:opaque_ref` で type に value-type 名 (URL 等) を渡された場合、 raw
      # pointer は NS-class に向けて unsafeBitCast し、 末尾に `as <ValueType>`
      # で bridge する。
      VALUE_TYPE_NS_BRIDGES = {
        "URL"        => "NSURL",
        "Data"       => "NSData",
        "String"     => "NSString",
        "Array"      => "NSArray",
        "Dictionary" => "NSDictionary",
        "Set"        => "NSSet",
        "Date"       => "NSDate"
      }.freeze

      def swift_bridged_class_name(klass)
        return klass.to_s if NS_STRIP_PRESERVE_LIST.include?(klass.to_s)
        klass.to_s.sub(/\ANS([A-Z])/, '\1')
      end

      # swift_init の return marshaling。opaque_ref を passRetained して
      # Ruby Integer へ。それ以外は基本 marshaling。
      # T54n — return_kind が Hash 形 (`{kind:, type:, nilable:}`) なら kind 抽出
      # して dispatch、 :array_of_opaque_ref など typed array 戻り値を marshal。
      def swift_init_return_lines(return_kind, var)
        kind_sym, _meta = unpack_return_kind(return_kind)
        case kind_sym
        when :opaque_ref
          [
            "let p = Unmanaged.passRetained(#{var} as AnyObject).toOpaque()",
            "return rb_ull2inum(UInt64(UInt(bitPattern: p)))"
          ]
        else
          objc_return_lines(return_kind, var)
        end
      end

      # T54n — return_kind を (kind_sym, meta) tuple に分解。 Symbol 形 →
      # ({kind_sym}, {})、 Hash 形 → ({:kind, type, nilable, ...} 全体保持)。
      def unpack_return_kind(return_kind)
        if return_kind.is_a?(Hash)
          [return_kind[:kind].to_sym, return_kind]
        else
          [return_kind.to_sym, {}]
        end
      end

      # T48 — instance method selector を Swift bridged call form に変換。
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
            # T52f — Apple SDK ObjC→Swift bridge convention: multi-segment
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
        head = lower_first_camel_local(head)
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

      # selector → Swift method 名 (spec §3.4.1)。
      # single-segment `stringWithUTF8String:` → `stringWithUTF8String`
      # multi-segment は init 専用が大半（T44 の instance method で本格対応）。
      # class method の multi-segment は rare、暫定的に最初の segment を採用。
      def swift_method_name_from_selector(selector)
        parts = selector.split(":", -1).reject(&:empty?)
        return selector if parts.empty?
        return parts[0] if parts.size == 1
        parts[0]
      end

      # T43 — class method を Swift call expression に変換。Swift 6 は
      # `+<verb>With<Type>:` shape の convenience constructors を init に rename
      # (e.g. NSString.stringWithUTF8String → NSString.init(utf8String:))。
      # この shape の selector は init form を emit する。それ以外は class method
      # form (`Klass.swiftMethod(args)`) を維持。
      def swift_call_for_class_method(klass, selector, params)
        parts = selector.split(":", -1).reject(&:empty?)
        if parts.size == 1
          sole = parts[0]
          # T52e/T52g — Apple ObjC→Swift bridge convention:
          # 1. `<verb>With<Type>:` (init bridge) → `<klass>(<typeAsLabel>: arg0)`
          #    label は lowerCamel(<Type>)。e.g. stringWithUTF8String →
          #    NSString(utf8String: arg0).
          # 2. `<verb><Preposition><Type>:` (For/By/Using/From/At/In/To/On)
          #    (class method bridge) → `<klass>.<verb>(<prepositionWithType>: arg0)`
          #    label は lowerCamel(<Preposition><Type>)。e.g. sleepForTimeInterval
          #    → Thread.sleep(forTimeInterval: arg0).
          if (m = sole.match(/\A([A-Za-z][a-zA-Z0-9]*?)With([A-Z]\w*)\z/))
            label = lower_first_camel_local(m[2])
            # T53c — utf8String / cString init bridges は raw UnsafePointer<CChar>
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
          head = lower_first_camel_local(head)
          labels = head.empty? ? parts[1..] : ([head] + parts[1..])
          args = params.each_index.map { |i| "arg#{i}" }
          label_args = labels.zip(args).map { |l, a| "#{l}: #{a}" }.join(", ")
          "#{klass}(#{label_args})"
        end
      end

      # acronym-aware first-word lowercase (Apple ObjC→Swift bridging rule)。
      # CGImage→cgImage, URL→url, HTTPHeader→httpHeader, Image→image,
      # UTF8String→utf8String (acronym + digit boundary も全 lowercase 化)。
      def lower_first_camel_local(s)
        return "" if s.empty?
        m = s.match(/\A[A-Z]+/)
        return s[0].downcase + (s[1..] || "") unless m
        run = m[0]
        return s.downcase if run.length == s.length
        return s[0].downcase + s[1..] if run.length == 1
        next_char = s[run.length]
        if next_char =~ /[a-z]/
          # 最後 upper letter が次の word を始める: 残りの acronym を lowercase。
          run[0..-2].downcase + run[-1] + s[run.length..]
        else
          # acronym 後が digit / 非 letter → run 全体を lowercase。
          run.downcase + s[run.length..]
        end
      end

      # objc/swift kind 用の inline argv binding。`:params` array の kind symbol
      # に応じて `let arg<i>` を Swift で declare。既存 Marshaller 経路は
      # parameters_json + clang AST type を要求するので、synth record（params:
      # symbol kinds の配列）専用に inline 展開する。
      # argv_offset: instance method の receiver 用に argv[0] を予約する場合に
      # +1 を指定 (argv index = arg index + offset)。default 0。
      def objc_in_load(kind_sym, index, argv_offset: 0)
        ai = index + argv_offset
        # T52d — Hash 形 (`{kind: :array_of_opaque_ref, type: "Operation"}`) と
        # Symbol 形 (`:block_persistent_void`) の両方を受ける。Hash 形は :type
        # ヒントを Swift cast 先 type として使う。
        kind_actual = kind_sym.is_a?(Hash) ? kind_sym[:kind] : kind_sym
        type_hint = kind_sym.is_a?(Hash) ? kind_sym[:type] : nil
        case kind_actual.to_sym
        when :string
          # T53c — Apple SDK の ObjC string 引数は Swift bridge で String を
          # expect する (URL.init(string:), NSString instance methods 等)。
          # `:string` in_load は Swift String を emit。 ただし
          # `+stringWithUTF8String:` のように historically raw cstr を取る
          # init bridge は依然必要なので、 cstr ポインタは `argN_cstr` 補助
          # 名で参照可能にする。
          <<~SWIFT.chomp
            var v#{index} = argv[#{ai}]
                let arg#{index}_cstr = rb_string_value_cstr(&v#{index})
                let arg#{index} = String(cString: arg#{index}_cstr)
          SWIFT
        when :int
          # T54q — Apple SDK の Swift bridged API は概ね Int 期待 (Vision の
          # topCandidates(_ maxCount: Int) 等)。 Int64 直渡しは Swift 6 で型
          # mismatch error になるため、 objc_in_load 経路 (objc_method_*/
          # swift_init/swift_property) では Int で emit。 KB-stored C function
          # path (IntMarshaller 経路) は引き続き Int64 を emit。
          "let arg#{index}: Int = Int(rb_num2ll(argv[#{ai}]))"
        when :bool
          "let arg#{index}: Bool = (argv[#{ai}] != Qfalse && argv[#{ai}] != Qnil)"
        when :float
          "let arg#{index}: Double = rb_num2dbl(argv[#{ai}])"
        when :opaque_ref
          # T52j — Hash 形 type ヒント (`{kind: :opaque_ref, type: "Operation"}`)
          # 指定時は Swift class 型に unsafeBitCast、 raw OpaquePointer を期待
          # する一般 C ABI 経路 (CoreMIDI 等) は type_hint 不在で従来挙動。
          # T53i — type が value-type (URL/Data/String/Array/Dict/Set/Date) の
          # 場合、 struct に対する unsafeBitCast は SIGTRAP のため、 NS-class
          # 経由で bridge: `unsafeBitCast(ptr, to: NSURL.self) as URL`。
          if type_hint
            ns_bridge = VALUE_TYPE_NS_BRIDGES[type_hint.to_s]
            cast_type = ns_bridge || type_hint
            tail_bridge = ns_bridge ? " as #{type_hint}" : ""
            <<~SWIFT.chomp
              let arg#{index}_raw_v = UInt(rb_num2ull(argv[#{ai}]))
                  guard let arg#{index}_ptr_v = OpaquePointer(bitPattern: arg#{index}_raw_v) else { return Qnil }
                  let arg#{index} = unsafeBitCast(arg#{index}_ptr_v, to: #{cast_type}.self)#{tail_bridge}
            SWIFT
          else
            "let arg#{index} = OpaquePointer(bitPattern: UInt(rb_num2ull(argv[#{ai}])))"
          end
        when :cftype_ref
          # T54k — Hash 形 (`{kind: :cftype_ref, type: "CGImage"}`) で typed
          # CFType reference に unsafeBitCast。 Vision の
          # `init(cgImage: CGImage, ...)` 等、 Swift bridged CFType class 引数を
          # expect する path で必須。 type_hint 不在時は raw OpaquePointer 維持
          # (CoreMIDI 系の opaque ref 渡しを壊さない)。
          # T54r — Apple SDK の CF*Create* 戻り値は box pointer (auto-ARC) で
          # 来るため、 runtime_arc_unbox_cftype で内部 CF pointer に unwrap する。
          # box でない raw pointer 直渡しは unbox が 0 を返すので raw に fallback。
          if type_hint
            <<~SWIFT.chomp
              let arg#{index}_raw_v = UInt(rb_num2ull(argv[#{ai}]))
                  let arg#{index}_unbox_v = runtime_arc_unbox_cftype(arg#{index}_raw_v)
                  let arg#{index}_actual_v: UInt = (arg#{index}_unbox_v != 0) ? arg#{index}_unbox_v : arg#{index}_raw_v
                  guard let arg#{index}_ptr_v = OpaquePointer(bitPattern: arg#{index}_actual_v) else { return Qnil }
                  let arg#{index} = unsafeBitCast(arg#{index}_ptr_v, to: #{type_hint}.self)
            SWIFT
          else
            "let arg#{index} = OpaquePointer(bitPattern: UInt(rb_num2ull(argv[#{ai}])))"
          end
        when :void_ptr_nilable
          "let arg#{index}: UnsafeMutableRawPointer? = (argv[#{ai}] == Qnil) ? nil : UnsafeMutableRawPointer(bitPattern: Int(rb_num2ll(argv[#{ai}])))"
        when :block_persistent
          # T48/T53a — escaping completion block。Ruby Proc を proc_registry に
          # pin、 @convention(block) closure を組み、 N-arg dispatch 経由で Ruby
          # callback を起動する。
          #
          # Hash 形 (T53a): `{kind: :block_persistent, arity: 3, types: ["NSData?",
          # "NSURLResponse?", "NSError?"]}` で typed signature + multi-arg
          # dispatch。 各 Optional は AnyObject? 経由 OpaquePointer に変換し
          # Int64 raw pointer (nil → 0) として runtime_threading_enqueue_3 で
          # main thread queue に積む。
          #
          # Symbol 形 (T48 既存): single-arg `(Error?) -> Void` 互換、
          # 1-arg `runtime_threading_enqueue` (err == nil ? 0 : -1) 経路維持。
          if kind_sym.is_a?(Hash) && kind_sym[:arity] == 3
            types = kind_sym[:types] || ["NSData?", "NSURLResponse?", "NSError?"]
            t0, t1, t2 = types
            <<~SWIFT.chomp
              let arg#{index}_pid_v = rb_obj_id(argv[#{ai}])
                  rb_hash_aset(runtime_proc_registry_get(), arg#{index}_pid_v, argv[#{ai}])
                  let arg#{index}_pid_u = rb_num2ull(arg#{index}_pid_v)
                  let arg#{index}: @convention(block) (#{t0}, #{t1}, #{t2}) -> Void = { (a0, a1, a2) in
                      let p0: Int64 = (a0 as AnyObject?).map { Int64(UInt(bitPattern: Unmanaged.passRetained($0).toOpaque())) } ?? 0
                      let p1: Int64 = (a1 as AnyObject?).map { Int64(UInt(bitPattern: Unmanaged.passRetained($0).toOpaque())) } ?? 0
                      let p2: Int64 = (a2 as AnyObject?).map { Int64(UInt(bitPattern: Unmanaged.passRetained($0).toOpaque())) } ?? 0
                      runtime_threading_enqueue_3(arg#{index}_pid_u, p0, p1, p2)
                  }
            SWIFT
          else
            <<~SWIFT.chomp
              let arg#{index}_pid_v = rb_obj_id(argv[#{ai}])
                  rb_hash_aset(runtime_proc_registry_get(), arg#{index}_pid_v, argv[#{ai}])
                  let arg#{index}_pid_u = rb_num2ull(arg#{index}_pid_v)
                  let arg#{index}_slot_id = runtime_callback_register_block_persistent(arg#{index}_pid_u)
                  _ = arg#{index}_slot_id
                  let arg#{index}: (Data?, URLResponse?, Error?) -> Void = { (data, resp, err) in
                      runtime_threading_enqueue(arg#{index}_pid_u, err == nil ? 0 : -1)
                  }
            SWIFT
          end
        when :block_persistent_void
          # T52a/T52d — () -> Void escaping block (NSBlockOperation の
          # +blockOperationWithBlock:)。Ruby Proc を proc_registry に pin、
          # @convention(block) () -> Void closure を組み、内部で
          # runtime_threading_enqueue 経由で Ruby callback を起動 (arg=0)。
          <<~SWIFT.chomp
            let arg#{index}_pid_v = rb_obj_id(argv[#{ai}])
                rb_hash_aset(runtime_proc_registry_get(), arg#{index}_pid_v, argv[#{ai}])
                let arg#{index}_pid_u = rb_num2ull(arg#{index}_pid_v)
                let arg#{index}: @convention(block) () -> Void = {
                    runtime_threading_enqueue(arg#{index}_pid_u, 0)
                }
          SWIFT
        when :nil_literal
          # T54l — Swift native 型 (Dict / Set / クラス struct 等) で raw pointer
          # から復元できない引数を nil 固定で渡す経路。 Apple SDK で options
          # 引数等が `[VNImageOption: Any]?` のように Optional な場合、
          # `Apple.discover(... params: [..., {kind: :nil_literal, type: "[VNImageOption: Any]"}])`
          # で Ruby 引数を無視して Swift `nil` を渡す。 type_hint は Swift 型注釈。
          # T54s — `:value` 指定時は Optional? を付けず concrete literal を emit
          # (Vision の `init(cgImage:, options: [:])` のように non-Optional default
          # 値を取る API 用)。 default は従来通り `nil`。
          swift_type = (type_hint || "AnyObject").to_s
          value_override = kind_sym.is_a?(Hash) ? kind_sym[:value] : nil
          if value_override
            "let arg#{index}: #{swift_type} = #{value_override}"
          else
            "let arg#{index}: #{swift_type}? = nil"
          end
        when :array_of_opaque_ref
          # T54a/T52d — Ruby Array<opaque ref Integer> → Swift [<Type>]。
          # Hash 形の :type を cast 先 type として使う。NSMutableArray を
          # populate して `as! [Type]` cast。 Type unknown なら "AnyObject"。
          element_type = (type_hint || "AnyObject").to_s
          <<~SWIFT.chomp
            let arg#{index}_nsma_v = NSMutableArray()
                let arg#{index}_count_v = runtime_rb_array_len(argv[#{ai}])
                for arg#{index}_k_v in 0..<arg#{index}_count_v {
                    let arg#{index}_raw_v = UInt(rb_num2ull(rb_ary_entry(argv[#{ai}], arg#{index}_k_v)))
                    if arg#{index}_raw_v == 0 { continue }
                    if let arg#{index}_ptr_v = OpaquePointer(bitPattern: arg#{index}_raw_v) {
                        let arg#{index}_obj_v = unsafeBitCast(arg#{index}_ptr_v, to: #{element_type}.self)
                        arg#{index}_nsma_v.add(arg#{index}_obj_v)
                    }
                }
                let arg#{index} = arg#{index}_nsma_v as! [#{element_type}]
          SWIFT
        else
          raise ArgumentError, "objc_in_load: unsupported param kind #{kind_sym.inspect}"
        end
      end

      # synth record の return_kind を Ruby VALUE 化する Swift snippet 列。
      # opaque_ref は ObjC instance を Unmanaged.passRetained で raw pointer 化。
      # T54n — Hash 形 return_kind 対応 (`:array_of_opaque_ref` 等)。
      def objc_return_lines(return_kind, var)
        kind_sym, meta = unpack_return_kind(return_kind)
        case kind_sym
        when :array_of_opaque_ref
          # T54n — Swift typed array (`[VNRecognizedTextObservation]?` 等) を
          # Ruby Array<Integer> に marshal。 各要素を passRetained で opaque
          # raw pointer 化、 Ruby Integer として rb_ary_push。
          element_type = (meta[:type] || "AnyObject").to_s
          nilable = meta[:nilable] != false  # default true (Apple SDK の results
                                              # 系は概ね Optional)
          if nilable
            [
              "guard let __arr = (#{var} as? [#{element_type}]) ?? (#{var} as Any as? [#{element_type}]) else { return Qnil }",
              "let __ary = rb_ary_new()",
              "for __obj in __arr {",
              "    let __p = Unmanaged.passRetained(__obj as AnyObject).toOpaque()",
              "    _ = rb_ary_push(__ary, rb_ull2inum(UInt64(UInt(bitPattern: __p))))",
              "}",
              "return __ary"
            ]
          else
            [
              "let __arr = #{var}",
              "let __ary = rb_ary_new()",
              "for __obj in __arr {",
              "    let __p = Unmanaged.passRetained(__obj as AnyObject).toOpaque()",
              "    _ = rb_ary_push(__ary, rb_ull2inum(UInt64(UInt(bitPattern: __p))))",
              "}",
              "return __ary"
            ]
          end
        when :opaque_ref
          # T52e — Swift 6 の Optional? / non-optional Self 両対応。
          # `#{var} as AnyObject?` で Optional<AnyObject> に強制 upcast し、
          # if-let で nil-check。これにより:
          # - 元が non-optional Self (BlockOperation init 等) → 常に non-nil
          #   AnyObject に bridge され、guard let が成立。
          # - 元が Optional T? → そのまま Optional<AnyObject> 化、nil 経路で Qnil。
          # `var!` の force unwrap も `var == nil` の常時 false 警告も避ける。
          [
            "guard let __ret = (#{var} as AnyObject?) else { return Qnil }",
            "let p = Unmanaged.passRetained(__ret).toOpaque()",
            "return rb_ull2inum(UInt64(UInt(bitPattern: p)))"
          ]
        when :int
          ["return rb_ll2inum(Int64(#{var}))"]
        when :string
          # T54p — Swift String? を Ruby String VALUE に marshal。
          # VNRecognizedText.string 等 Swift bridged String property 用。
          # Optional? を一旦 String? に upcast して if-let、 nil なら Qnil、
          # non-nil なら withCString 経由で rb_str_new_cstr に渡す。
          [
            "if let __s = (#{var} as String?) {",
            "    return __s.withCString { rb_str_new_cstr($0) }",
            "}",
            "return Qnil"
          ]
        when :raw_ptr
          # T53h — UnsafeRawPointer? / UnsafePointer<T>? 等 raw pointer の
          # raw bit pattern を Ruby Integer に。 Data 内部 buffer (`bytes`) や
          # その他 const void* 戻り値で使う。 Unmanaged.passRetained は呼ばない
          # (raw pointer は NSObject ではない)。
          ["return rb_ull2inum(UInt64(UInt(bitPattern: #{var})))"]
        when :bool
          ["return #{var} ? Qtrue : Qfalse"]
        when :float
          # T54v — Apple SDK の Float type alias (VNConfidence = Float 等) は
          # Swift 6 で Double に暗黙変換されないため、 明示 Double() cast。
          ["return rb_float_new(Double(#{var}))"]
        when :void
          ["return Qnil"]
        else
          raise ArgumentError, "objc_return_lines: unsupported return_kind #{return_kind.inspect}"
        end
      end

      private

      def parse_params(json)
        return [] if json.nil? || json.empty?
        JSON.parse(json, symbolize_names: true)
      end

      # Phase 7 T4 — when the knowledge record marks a symbol with
      # cf_create_rule (clang AST CF_RETURNS_RETAINED / Create / Copy naming
      # heuristic), upgrade a CF*Ref return to cftype_ref_autoarc so the
      # auto-ARC path fires.
      # T50 — Apple.discover の return_kind: override が来た場合 (synth record
      # に :return_kind が入っている)、signature regex を bypass してそれを
      # 直接使う。`int` override は status_int (OSStatus check 付き) ではなく
      # plain int として marshal される。
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
        return "cftype_ref_autoarc" if symbol[:cf_create_rule]
        # Spec §5: naming-prefix heuristic ("Create" / "Copy") fills the gap
        # when the clang AST attribute is missing. Per CF ownership rules,
        # any CF*Create* / CF*Copy* function returns a +1-retained reference
        # the caller must release — so it's auto-ARC eligible.
        return "cftype_ref_autoarc" if cf_create_naming?(symbol[:name])
        kind
      end

      def cf_create_naming?(name)
        name.to_s =~ /\A(?:CF|CG|CV|CT|CM|CL|IO|Sec|AX)\w*(?:Create|Copy)/
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
          # User is responsible for CFRelease (no ARC bridging in Phase 7).
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
