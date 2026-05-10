# frozen_string_literal: true

module AppleSDKMac
  class GlueCompiler
    # Pure marshalling-by-kind for ObjC method param load + return marshaling.
    # Stateless module-level methods. Used by TemplateGenerator's
    # emit_objc_class_method / emit_objc_instance_method / emit_swift_init /
    # emit_swift_property to produce the Swift fragments that bind argv[i] →
    # let argN and that produce the Ruby VALUE return marshaling.
    #
    # Hash-form param entries (`{kind: :opaque_ref, type: "VNRequest"}`)
    # carry an explicit Swift cast type the Knowledge Base classifier could
    # not infer; Symbol-form entries fall back to bare OpaquePointer.
    module ObjcMarshalling
      # Swift value-type ↔ NSObject class bridge map. Hash-form `:opaque_ref`
      # with a value-type name (URL, Data, etc.) cannot use a struct
      # unsafeBitCast (SIGTRAP); instead we unsafeBitCast to the NSClass and
      # bridge with `as <ValueType>` at the tail.
      VALUE_TYPE_NS_BRIDGES = {
        "URL"        => "NSURL",
        "Data"       => "NSData",
        "String"     => "NSString",
        "Array"      => "NSArray",
        "Dictionary" => "NSDictionary",
        "Set"        => "NSSet",
        "Date"       => "NSDate"
      }.freeze

      module_function

      # return_kind を (kind_sym, meta) tuple に分解。 Symbol 形 →
      # ({kind_sym}, {})、 Hash 形 → ({:kind, type, nilable, ...} 全体保持)。
      def unpack_return_kind(return_kind)
        if return_kind.is_a?(Hash)
          [return_kind[:kind].to_sym, return_kind]
        else
          [return_kind.to_sym, {}]
        end
      end

      # objc/swift kind 用の inline argv binding。`:params` array の kind symbol
      # に応じて `let arg<i>` を Swift で declare。 既存 Marshaller 経路は
      # parameters_json + clang AST type を要求するので、 synth record (params:
      # symbol kinds の配列) 専用に inline 展開する。
      # argv_offset: instance method の receiver 用に argv[0] を予約する場合に
      # +1 を指定 (argv index = arg index + offset)。 default 0。
      def in_load(kind_sym, index, argv_offset: 0)
        ai = index + argv_offset
        # Hash 形 (`{kind: :array_of_opaque_ref, type: "Operation"}`) と
        # Symbol 形 (`:block_persistent_void`) の両方を受ける。 Hash 形は
        # :type ヒントを Swift cast 先 type として使う。
        kind_actual = kind_sym.is_a?(Hash) ? kind_sym[:kind] : kind_sym
        type_hint = kind_sym.is_a?(Hash) ? kind_sym[:type] : nil
        case kind_actual.to_sym
        when :string
          # Apple SDK の ObjC string 引数は Swift bridge で String を
          # expect する (URL.init(string:), NSString instance methods 等)。
          # `:string` in_load は Swift String を emit。 ただし
          # `+stringWithUTF8String:` のように raw cstr を取る init bridge は
          # 依然必要なので、 cstr ポインタは `argN_cstr` 補助名で参照可能にする。
          <<~SWIFT.chomp
            var v#{index} = argv[#{ai}]
                let arg#{index}_cstr = rb_string_value_cstr(&v#{index})
                let arg#{index} = String(cString: arg#{index}_cstr)
          SWIFT
        when :int
          # Apple SDK の Swift bridged API は概ね Int 期待 (Vision の
          # topCandidates(_ maxCount: Int) 等)。 Int64 直渡しは Swift 6 で型
          # mismatch error になるため、 in_load 経路 (objc_method_*/
          # swift_init/swift_property) では Int で emit。 Knowledge Base 由来の
          # C function path (IntMarshaller 経路) は引き続き Int64 を emit。
          "let arg#{index}: Int = Int(rb_num2ll(argv[#{ai}]))"
        when :bool
          "let arg#{index}: Bool = (argv[#{ai}] != Qfalse && argv[#{ai}] != Qnil)"
        when :float
          "let arg#{index}: Double = rb_num2dbl(argv[#{ai}])"
        when :opaque_ref
          # Hash 形 type ヒント (`{kind: :opaque_ref, type: "Operation"}`)
          # 指定時は Swift class 型に unsafeBitCast、 raw OpaquePointer を期待
          # する一般 C ABI 経路 (CoreMIDI 等) は type_hint 不在で従来挙動。
          # type が value-type (URL/Data/String/Array/Dict/Set/Date) の
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
          # Hash 形 (`{kind: :cftype_ref, type: "CGImage"}`) で typed
          # CFType reference に unsafeBitCast。 Vision の
          # `init(cgImage: CGImage, ...)` 等、 Swift bridged CFType class 引数を
          # expect する path で必須。 type_hint 不在時は raw OpaquePointer 維持
          # (CoreMIDI 系の opaque ref 渡しを壊さない)。
          # Apple SDK の CF*Create* 戻り値は box pointer (auto-ARC) で来るため、
          # runtime_arc_unbox_cftype で内部 CF pointer に unwrap する。
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
          # Escaping completion block。 Ruby Proc を proc_registry に pin、
          # @convention(block) closure を組み、 N-arg dispatch 経由で Ruby
          # callback を起動する。
          #
          # Hash 形: `{kind: :block_persistent, arity: 3, types: ["NSData?",
          # "NSURLResponse?", "NSError?"]}` で typed signature + multi-arg
          # dispatch。 各 Optional は AnyObject? 経由 OpaquePointer に変換し
          # Int64 raw pointer (nil → 0) として runtime_threading_enqueue_3 で
          # main thread queue に積む。
          #
          # Symbol 形: single-arg `(Error?) -> Void` 互換、 1-arg
          # `runtime_threading_enqueue` (err == nil ? 0 : -1) 経路維持。
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
          # `() -> Void` escaping block (NSBlockOperation の
          # +blockOperationWithBlock:)。 Ruby Proc を proc_registry に pin、
          # @convention(block) () -> Void closure を組み、 内部で
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
          # Swift native 型 (Dict / Set / クラス struct 等) で raw pointer
          # から復元できない引数を nil 固定で渡す経路。 Apple SDK で options
          # 引数等が `[VNImageOption: Any]?` のように Optional な場合、
          # `Apple.discover(... params: [..., {kind: :nil_literal, type: "[VNImageOption: Any]"}])`
          # で Ruby 引数を無視して Swift `nil` を渡す。 type_hint は Swift 型注釈。
          # `:value` 指定時は Optional? を付けず concrete literal を emit
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
          # Ruby Array<opaque ref Integer> → Swift [<Type>]。
          # Hash 形の :type を cast 先 type として使う。 NSMutableArray を
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
          raise ArgumentError, "ObjcMarshalling.in_load: unsupported param kind #{kind_sym.inspect}"
        end
      end

      # synth record の return_kind を Ruby VALUE 化する Swift snippet 列。
      # opaque_ref は ObjC instance を Unmanaged.passRetained で raw pointer 化。
      # Hash 形 return_kind 対応 (`:array_of_opaque_ref` 等)。
      def return_lines(return_kind, var)
        kind_sym, meta = unpack_return_kind(return_kind)
        case kind_sym
        when :array_of_opaque_ref
          # Swift typed array (`[VNRecognizedTextObservation]?` 等) を Ruby
          # Array<Integer> に marshal。 各要素を passRetained で opaque raw
          # pointer 化、 Ruby Integer として rb_ary_push。
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
          # Swift 6 の Optional? / non-optional Self 両対応。
          # `#{var} as AnyObject?` で Optional<AnyObject> に強制 upcast し、
          # if-let で nil-check。 これにより:
          # - 元が non-optional Self (BlockOperation init 等) → 常に non-nil
          #   AnyObject に bridge され、 guard let が成立。
          # - 元が Optional T? → そのまま Optional<AnyObject> 化、 nil 経路で Qnil。
          # `var!` の force unwrap も `var == nil` の常時 false 警告も避ける。
          [
            "guard let __ret = (#{var} as AnyObject?) else { return Qnil }",
            "let p = Unmanaged.passRetained(__ret).toOpaque()",
            "return rb_ull2inum(UInt64(UInt(bitPattern: p)))"
          ]
        when :int
          ["return rb_ll2inum(Int64(#{var}))"]
        when :string
          # Swift String? を Ruby String VALUE に marshal。
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
          # UnsafeRawPointer? / UnsafePointer<T>? 等 raw pointer の raw bit
          # pattern を Ruby Integer に。 Data 内部 buffer (`bytes`) や
          # const void* 戻り値で使う。 Unmanaged.passRetained は呼ばない
          # (raw pointer は NSObject ではない)。
          ["return rb_ull2inum(UInt64(UInt(bitPattern: #{var})))"]
        when :bool
          ["return #{var} ? Qtrue : Qfalse"]
        when :float
          # Apple SDK の Float type alias (VNConfidence = Float 等) は
          # Swift 6 で Double に暗黙変換されないため、 明示 Double() cast。
          ["return rb_float_new(Double(#{var}))"]
        when :void
          ["return Qnil"]
        else
          raise ArgumentError, "ObjcMarshalling.return_lines: unsupported return_kind #{return_kind.inspect}"
        end
      end
    end
  end
end
