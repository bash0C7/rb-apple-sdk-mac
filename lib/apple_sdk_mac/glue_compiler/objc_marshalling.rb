# frozen_string_literal: true

module AppleSDKMac
  class GlueCompiler
    module ObjcMarshalling
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

      def unpack_return_kind(return_kind)
        if return_kind.is_a?(Hash)
          [return_kind[:kind].to_sym, return_kind]
        else
          [return_kind.to_sym, {}]
        end
      end

      def in_load(kind_sym, index, argv_offset: 0)
        ai = index + argv_offset
        kind_actual = kind_sym.is_a?(Hash) ? kind_sym[:kind] : kind_sym
        type_hint = kind_sym.is_a?(Hash) ? kind_sym[:type] : nil
        case kind_actual.to_sym
        when :string
          <<~SWIFT.chomp
            var v#{index} = argv[#{ai}]
                let arg#{index}_cstr = rb_string_value_cstr(&v#{index})
                let arg#{index} = String(cString: arg#{index}_cstr)
          SWIFT
        when :int
          "let arg#{index}: Int = Int(rb_num2ll(argv[#{ai}]))"
        when :uint32
          "let arg#{index}: UInt32 = UInt32(rb_num2ull(argv[#{ai}]))"
        when :bool
          "let arg#{index}: Bool = (argv[#{ai}] != Qfalse && argv[#{ai}] != Qnil)"
        when :float
          "let arg#{index}: Double = rb_num2dbl(argv[#{ai}])"
        when :opaque_ref
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
          <<~SWIFT.chomp
            let arg#{index}_pid_v = rb_obj_id(argv[#{ai}])
                rb_hash_aset(runtime_proc_registry_get(), arg#{index}_pid_v, argv[#{ai}])
                let arg#{index}_pid_u = rb_num2ull(arg#{index}_pid_v)
                let arg#{index}: @convention(block) () -> Void = {
                    runtime_threading_enqueue(arg#{index}_pid_u, 0)
                }
          SWIFT
        when :nil_literal
          swift_type = (type_hint || "AnyObject").to_s
          value_override = kind_sym.is_a?(Hash) ? kind_sym[:value] : nil
          if value_override
            "let arg#{index}: #{swift_type} = #{value_override}"
          else
            "let arg#{index}: #{swift_type}? = nil"
          end
        when :array_of_opaque_ref
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

      def return_lines(return_kind, var)
        kind_sym, meta = unpack_return_kind(return_kind)
        case kind_sym
        when :array_of_opaque_ref
          element_type = (meta[:type] || "AnyObject").to_s
          nilable = meta[:nilable] != false
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
          [
            "guard let __ret = (#{var} as AnyObject?) else { return Qnil }",
            "let p = Unmanaged.passRetained(__ret).toOpaque()",
            "return rb_ull2inum(UInt64(UInt(bitPattern: p)))"
          ]
        when :int
          ["return rb_ll2inum(Int64(#{var}))"]
        when :string
          [
            "if let __s = (#{var} as String?) {",
            "    return __s.withCString { rb_str_new_cstr($0) }",
            "}",
            "return Qnil"
          ]
        when :raw_ptr
          ["return rb_ull2inum(UInt64(UInt(bitPattern: #{var})))"]
        when :bool
          ["return #{var} ? Qtrue : Qfalse"]
        when :float
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
