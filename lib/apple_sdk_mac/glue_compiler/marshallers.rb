# frozen_string_literal: true
require "set"

module AppleSDKMac
  class GlueCompiler
    class Marshaller
      attr_reader :param, :index, :ctx

      def initialize(param, index, ctx)
        @param = param
        @index = index
        @ctx = ctx
      end

      def in_load;      nil end
      def call_arg;     @param[:name] end
      def out_post_call; nil end
      def out_handling; nil end
      def call_wrapper(inner); inner end

      REGISTRY = {}

      def self.for(param, index, ctx)
        klass = REGISTRY[param[:kind]]
        return nil unless klass
        m = klass.new(param, index, ctx)
        return nil if m.respond_to?(:broken?) && m.broken?
        m
      end
    end

    class StringMarshaller < Marshaller
      def in_load
        cast = @param[:type].include?("CFString") ? " as CFString" :
               @param[:type].include?("NSString") ? " as NSString" : ""
        "var v#{@index} = argv[#{@index}]; let #{@param[:name]} = String(cString: rb_string_value_cstr(&v#{@index}))#{cast}"
      end
    end
    Marshaller::REGISTRY["string"] = StringMarshaller

    class IntMarshaller < Marshaller
      def in_load
        return nil if @param[:is_out_param]
        "let #{@param[:name]}: Int64 = rb_num2ll(argv[#{@index}])"
      end

      def call_arg
        return "&#{@param[:name]}" if @param[:is_out_param]
        ctype = scalar_type_token(@param[:type])
        return @param[:name] if ctype.nil? || ctype == "Int64"
        "numericCast(#{@param[:name]})"
      end

      def out_handling
        return nil unless @param[:is_out_param]
        ctype = scalar_type_token(@param[:type]) || "Int64"
        {
          init: "var #{@param[:name]}: #{ctype} = 0",
          addr: "&#{@param[:name]}",
          to_ruby: unsigned?(@param[:type]) \
            ? "rb_ull2inum(UInt64(#{@param[:name]}))"
            : "rb_ll2inum(Int64(#{@param[:name]}))"
        }
      end

      private

      def scalar_type_token(raw)
        cleaned = raw.to_s.strip
                     .sub(/\Aconst\s+/, "")
                     .gsub(/\b_(Nonnull|Nullable)\b/, "")
                     .sub(/\s*\*+\s*\z/, "")
                     .strip
        return nil if cleaned.empty? || cleaned.include?("*") || cleaned == "void"
        cleaned
      end

      def unsigned?(t)
        t.match?(/\b(UInt|UInt8|UInt16|UInt32|UInt64|uint(8|16|32|64)_t|unsigned)\b/)
      end
    end
    Marshaller::REGISTRY["int"] = IntMarshaller

    class BoolMarshaller < Marshaller
      def in_load
        return nil if @param[:is_out_param]
        "let #{@param[:name]}: Bool = (argv[#{@index}] != Qfalse && argv[#{@index}] != Qnil)"
      end

      def call_arg
        return "&#{@param[:name]}" if @param[:is_out_param]
        @param[:name]
      end

      def out_handling
        return nil unless @param[:is_out_param]
        {
          init:    "var #{@param[:name]}: Bool = false",
          addr:    "&#{@param[:name]}",
          to_ruby: "#{@param[:name]} ? Qtrue : Qfalse"
        }
      end
    end
    Marshaller::REGISTRY["bool"] = BoolMarshaller

    class FloatMarshaller < Marshaller
      def in_load
        return nil if @param[:is_out_param]
        "let #{@param[:name]}: Double = rb_num2dbl(argv[#{@index}])"
      end

      def call_arg
        return "&#{@param[:name]}" if @param[:is_out_param]
        @param[:name]
      end

      def out_handling
        return nil unless @param[:is_out_param]
        return nil if @param[:type].to_s.scan("*").length > 1
        swift_type = scalar_float_type(@param[:type]) || "Double"
        to_ruby = (swift_type == "Double") \
          ? "rb_float_new(#{@param[:name]})"
          : "rb_float_new(Double(#{@param[:name]}))"
        {
          init:    "var #{@param[:name]}: #{swift_type} = 0",
          addr:    "&#{@param[:name]}",
          to_ruby: to_ruby
        }
      end

      private

      def scalar_float_type(raw)
        cleaned = raw.to_s.strip
                     .sub(/\Aconst\s+/, "")
                     .gsub(/\b_(Nonnull|Nullable)\b/, "")
                     .sub(/\s*\*+\s*\z/, "")
                     .strip
        return nil if cleaned.empty? || cleaned.include?("*") || cleaned == "void"
        return nil unless cleaned.match?(/\A[A-Za-z_]\w*\z/)
        return "Float"  if cleaned == "float"
        return "Double" if cleaned == "double"
        cleaned
      end
    end
    Marshaller::REGISTRY["float"] = FloatMarshaller

    class OpaqueRefMarshaller < Marshaller
      def in_load
        return nil if @param[:is_out_param]
        ref_type = strip_pointer(@param[:type])
        if unsigned?(@param[:type])
          "let #{@param[:name]} = #{ref_type}(rb_num2ull(argv[#{@index}]))"
        else
          "let #{@param[:name]} = #{ref_type}(rb_num2ll(argv[#{@index}]))"
        end
      end

      def call_arg
        @param[:is_out_param] ? "&#{@param[:name]}" : @param[:name]
      end

      def out_handling
        return nil unless @param[:is_out_param]
        ref_type = strip_pointer(@param[:type])
        to_ruby = unsigned?(@param[:type]) \
          ? "rb_ull2inum(UInt64(#{@param[:name]}))"
          : "rb_ll2inum(Int64(#{@param[:name]}))"
        {
          init:    "var #{@param[:name]}: #{ref_type} = #{ref_type}()",
          addr:    "&#{@param[:name]}",
          to_ruby: to_ruby
        }
      end

      private

      def strip_pointer(t)
        t.sub(/\s*\*.*\z/, "").gsub(/\b_(Nonnull|Nullable)\b/, "").strip
      end

      def unsigned?(t)
        return true  if t.match?(/\b(UInt|UInt8|UInt16|UInt32|UInt64|uint(8|16|32|64)_t|unsigned)\b/)
        return false if t.match?(/\b(SInt|SInt8|SInt16|SInt32|SInt64|int(8|16|32|64)_t|signed)\b/)
        t.match?(/\b\w+Ref\b/)
      end
    end
    Marshaller::REGISTRY["opaque_ref"] = OpaqueRefMarshaller

    class CFTypeRefMarshaller < Marshaller
      def in_load
        return nil if @param[:is_out_param]
        type = ref_type(@param[:type])
        name = @param[:name]; i = @index
        <<~SWIFT.chomp
          let #{name}: #{type}?
              if argv[#{i}] == Qnil {
                  #{name} = nil
              } else {
                  let __raw_in_#{i} = UInt(rb_num2ull(argv[#{i}]))
                  let __unbox_#{i} = runtime_arc_unbox_cftype(__raw_in_#{i})
                  let __actual_#{i}: UInt = (__unbox_#{i} != 0) ? __unbox_#{i} : __raw_in_#{i}
                  if __actual_#{i} == 0 {
                      #{name} = nil
                  } else if let __ptr_#{i} = OpaquePointer(bitPattern: __actual_#{i}) {
                      #{name} = unsafeBitCast(__ptr_#{i}, to: #{type}.self)
                  } else {
                      #{name} = nil
                  }
              }
        SWIFT
      end

      def call_arg
        return "&#{@param[:name]}" if @param[:is_out_param]
        return "#{@param[:name]}!" if @param[:nilable] == false
        @param[:name]
      end

      def out_handling
        return nil unless @param[:is_out_param]
        type = ref_type(@param[:type])
        {
          init:    "var #{@param[:name]}: #{type}? = nil",
          addr:    "&#{@param[:name]}",
          to_ruby: "rb_ull2inum(UInt64(UInt(bitPattern: unsafeBitCast(#{@param[:name]}!, to: OpaquePointer.self))))"
        }
      end

      private

      def ref_type(t)
        base = t.sub(/\Aconst\s+/, "")
                .sub(/\s*\*.*\z/, "")
                .gsub(/\b_(Nonnull|Nullable)\b/, "")
                .strip
        base.sub(/Ref\z/, "")
      end
    end
    Marshaller::REGISTRY["cftype_ref"] = CFTypeRefMarshaller

    CALLBACK_PILLAR_ROUTES = {
      "MIDINotifyProc" => :midi_notify,
      "MIDIReadProc"   => :midi_read
    }.freeze

    class CallbackNilableMarshaller < Marshaller
      def in_load
        type = @param[:type].sub(/\s*_(?:Nullable|Nonnull)\b/, "").strip
        name = @param[:name]; i = @index
        route = CALLBACK_PILLAR_ROUTES.fetch(type) do
          raise "callback type #{type.inspect} has no CallbackPillar route — extend CALLBACK_PILLAR_ROUTES + ext/apple_sdk_mac_runtime/callback_signatures.yml"
        end
        register_branch(name, type, i, route)
      end

      private

      def register_branch(name, type, i, route)
        fn_register = "runtime_callback_pillar_register_#{route}"
        fn_get_fnptr = "runtime_callback_pillar_get_#{route}_fnptr"
        <<~SWIFT.chomp
          let #{name}: #{type}?
              if argv[#{i}] == Qnil {
                  #{name} = nil
              } else {
                  let #{name}_pid_v = rb_obj_id(argv[#{i}])
                  let #{name}_reg = runtime_proc_registry_get()
                  rb_hash_aset(#{name}_reg, #{name}_pid_v, argv[#{i}])
                  let #{name}_pid_u = rb_num2ull(#{name}_pid_v)
                  let #{name}_slot = #{fn_register}(#{name}_pid_u)
                  if #{name}_slot < 0 { rb_raise(rb_eRuntimeError, "callback slot pool exhausted") }
                  let #{name}_raw = #{fn_get_fnptr}(#{name}_slot)
                  #{name} = unsafeBitCast(UnsafeRawPointer(bitPattern: UInt(#{name}_raw))!, to: #{type}.self)
              }
        SWIFT
      end
    end
    Marshaller::REGISTRY["callback_nilable"] = CallbackNilableMarshaller

    class CallbackNonNilMarshaller < Marshaller
      def initialize(param, index, ctx)
        super
        type = @param[:type].sub(/\s*_(?:Nullable|Nonnull)\b/, "").strip
        @route = CALLBACK_PILLAR_ROUTES[type]
        @broken = @route.nil?
      end

      def broken?; @broken; end

      def in_load
        return nil if @broken
        type = @param[:type].sub(/\s*_(?:Nullable|Nonnull)\b/, "").strip
        name = @param[:name]; i = @index
        fn_register = "runtime_callback_pillar_register_#{@route}"
        fn_get_fnptr = "runtime_callback_pillar_get_#{@route}_fnptr"
        <<~SWIFT.chomp
          let #{name}_pid_v = rb_obj_id(argv[#{i}])
              let #{name}_reg = runtime_proc_registry_get()
              rb_hash_aset(#{name}_reg, #{name}_pid_v, argv[#{i}])
              let #{name}_pid_u = rb_num2ull(#{name}_pid_v)
              let #{name}_slot = #{fn_register}(#{name}_pid_u)
              if #{name}_slot < 0 { rb_raise(rb_eRuntimeError, "callback slot pool exhausted") }
              let #{name}_raw = #{fn_get_fnptr}(#{name}_slot)
              let #{name}: #{type} = unsafeBitCast(UnsafeRawPointer(bitPattern: UInt(#{name}_raw))!, to: #{type}.self)
        SWIFT
      end
    end
    Marshaller::REGISTRY["callback_non_nil"] = CallbackNonNilMarshaller

    class BlockNilableMarshaller < Marshaller
      def in_load
        name = @param[:name]
        i = @index
        args, ret = parse_block_type(@param[:type])
        arg_decl = args.each_with_index.map { |t, k| "_a#{k}: #{t}" }.join(", ")
        dispatch_arg = block_dispatch_arg(args)
        block_param_types = args.join(", ")
        <<~SWIFT.chomp
          let #{name}: (@convention(block) (#{block_param_types}) -> #{ret})?
              if argv[#{i}] == Qnil {
                  #{name} = nil
              } else {
                  let #{name}_pid_v = rb_obj_id(argv[#{i}])
                  rb_hash_aset(runtime_proc_registry_get(), #{name}_pid_v, argv[#{i}])
                  let #{name}_pid_u = rb_num2ull(#{name}_pid_v)
                  #{name} = { (#{arg_decl}) in
                      ThreadingBridge.enqueueFromAppleThread(procId: #{name}_pid_u, arg: #{dispatch_arg})
                  }
              }
        SWIFT
      end

      private

      def parse_block_type(type)
        m = type.match(/\A(?<ret>\w+)\s*\(\s*\^\s*\)\s*\((?<args>[^)]*)\)/) or
          raise "BlockNilableMarshaller: unparseable block type #{type.inspect}"
        ret = m[:ret] == "void" ? "Void" : m[:ret]
        args_str = m[:args].to_s.strip
        args = if args_str.empty? || args_str == "void"
                 []
               else
                 args_str.split(",").map { |a| objc_arg_to_swift(a.strip) }
               end
        [args, ret]
      end

      def objc_arg_to_swift(t)
        base = t.gsub(/\s*\*\s*\z/, "").gsub(/\b_(Nonnull|Nullable)\b/, "").strip
        "#{base}?"
      end

      def block_dispatch_arg(args)
        return "0" if args.empty?
        if args.first.start_with?("NSError")
          "_a0 == nil ? 0 : -1"
        else
          "0"
        end
      end
    end
    Marshaller::REGISTRY["block_nilable"] = BlockNilableMarshaller

    class BlockPersistentMarshaller < Marshaller
      def in_load
        name = @param[:name]
        i = @index
        <<~SWIFT.chomp
          let #{name}_handle: BoxedBlockHandle?
              if argv[#{i}] == Qnil {
                  #{name}_handle = nil
              } else {
                  let #{name}_pid_v = rb_obj_id(argv[#{i}])
                  rb_hash_aset(runtime_proc_registry_get(), #{name}_pid_v, argv[#{i}])
                  let #{name}_pid_u = rb_num2ull(#{name}_pid_v)
                  let #{name}_slot_id = runtime_callback_register_block_persistent(#{name}_pid_u)
                  #{name}_handle = BoxedBlockHandle(slotId: #{name}_slot_id)
              }
        SWIFT
      end

      def call_arg
        "#{@param[:name]}_handle.map { runtime_callback_get_block_persistent_thunk($0.slotId) }"
      end
    end
    Marshaller::REGISTRY["block_persistent"] = BlockPersistentMarshaller

    class BlockPersistentVoidMarshaller < Marshaller
      def in_load
        name = @param[:name]
        i = @index
        <<~SWIFT.chomp
          let #{name}: (@convention(block) () -> Void)?
              if argv[#{i}] == Qnil {
                  #{name} = nil
              } else {
                  let #{name}_pid_v = rb_obj_id(argv[#{i}])
                  rb_hash_aset(runtime_proc_registry_get(), #{name}_pid_v, argv[#{i}])
                  let #{name}_pid_u = rb_num2ull(#{name}_pid_v)
                  #{name} = {
                      ThreadingBridge.enqueueFromAppleThread(procId: #{name}_pid_u, arg: 0)
                  }
              }
        SWIFT
      end
    end
    Marshaller::REGISTRY["block_persistent_void"] = BlockPersistentVoidMarshaller

    class VoidPtrNilableMarshaller < Marshaller
      def in_load
        name = @param[:name]; i = @index
        <<~SWIFT.chomp
          let #{name}: UnsafeMutableRawPointer?
              if argv[#{i}] == Qnil {
                  #{name} = nil
              } else {
                  #{name} = UnsafeMutableRawPointer(bitPattern: Int(rb_num2ll(argv[#{i}])))
              }
        SWIFT
      end
    end
    Marshaller::REGISTRY["void_ptr_nilable"] = VoidPtrNilableMarshaller

    class ArrayOfOpaqueRefMarshaller < Marshaller
      def in_load
        return nil if @param[:is_out_param]
        name = @param[:name]
        i = @index
        type = element_type(@param[:type])
        <<~SWIFT.chomp
          let #{name}_nsma_v = NSMutableArray()
              let #{name}_count_v = runtime_rb_array_len(argv[#{i}])
              for #{name}_k_v in 0..<#{name}_count_v {
                  let #{name}_raw_v = UInt(rb_num2ull(rb_ary_entry(argv[#{i}], #{name}_k_v)))
                  if #{name}_raw_v == 0 { continue }
                  if let #{name}_ptr_v = OpaquePointer(bitPattern: #{name}_raw_v) {
                      let #{name}_obj_v = unsafeBitCast(#{name}_ptr_v, to: #{type}.self)
                      #{name}_nsma_v.add(#{name}_obj_v)
                  }
              }
              let #{name} = #{name}_nsma_v as! [#{type}]
        SWIFT
      end

      private

      def element_type(t)
        t.to_s.sub(/\Aconst\s+/, "")
              .sub(/\s*\*.*\z/, "")
              .gsub(/\b_(Nonnull|Nullable)\b/, "")
              .strip
              .sub(/Ref\z/, "")
      end
    end
    Marshaller::REGISTRY["array_of_opaque_ref"] = ArrayOfOpaqueRefMarshaller

    class StructInMarshaller < Marshaller
      def initialize(param, index, ctx)
        super
        @broken = false
        @lines = build_in_load_lines
      end

      def broken?; @broken; end

      def in_load
        @lines
      end

      def call_arg
        "&#{@param[:name]}_struct"
      end

      private

      def build_in_load_lines
        type = struct_type(@param[:type])
        return mark_broken if @ctx[:struct_visited].include?(type)
        return mark_broken unless @ctx[:knowledge_cache]
        sym = @ctx[:knowledge_cache].lookup_symbol(framework: @ctx[:framework], symbol: type)
        return mark_broken unless sym && sym[:fields_json]
        fields = JSON.parse(sym[:fields_json], symbolize_names: true)

        @ctx[:struct_visited] << type
        name = @param[:name]
        i = @index
        lines = ["let #{name}_h = argv[#{i}]", "var #{name}_struct = #{type}()"]
        fields.each do |f|
          lines.concat(field_load_lines(f, "#{name}_h", "#{name}_struct.#{f[:name]}"))
          return mark_broken if @broken
        end
        @ctx[:struct_visited].delete(type)
        lines.join("\n    ")
      end

      def field_load_lines(field, parent_h, target_path)
        key = field[:name]
        case field[:kind]
        when "int"
          ["#{target_path} = #{strip_annotations(field[:type])}(rb_num2ll(rb_hash_aref(#{parent_h}, rb_str_new_cstr(\"#{key}\"))))"]
        when "float"
          ["#{target_path} = rb_num2dbl(rb_hash_aref(#{parent_h}, rb_str_new_cstr(\"#{key}\")))"]
        when "bool"
          ["#{target_path} = (rb_hash_aref(#{parent_h}, rb_str_new_cstr(\"#{key}\")) != Qfalse)"]
        when "string"
          tmp = "#{parent_h}_#{key}_v"
          ["var #{tmp} = rb_hash_aref(#{parent_h}, rb_str_new_cstr(\"#{key}\"))",
           "#{target_path} = String(cString: rb_string_value_cstr(&#{tmp}))"]
        when "opaque_ref"
          ["#{target_path} = #{strip_annotations(field[:type])}(rb_num2ull(rb_hash_aref(#{parent_h}, rb_str_new_cstr(\"#{key}\"))))"]
        when "struct_in"
          nested_type = strip_annotations(field[:type])
          if @ctx[:struct_visited].include?(nested_type)
            mark_broken
            return []
          end
          sym = @ctx[:knowledge_cache] && @ctx[:knowledge_cache].lookup_symbol(framework: @ctx[:framework], symbol: nested_type)
          unless sym && sym[:fields_json]
            mark_broken
            return []
          end
          nested_fields = JSON.parse(sym[:fields_json], symbolize_names: true)
          @ctx[:struct_visited] << nested_type
          nested_h = "#{parent_h}_#{key}_h"
          inner = ["let #{nested_h} = rb_hash_aref(#{parent_h}, rb_str_new_cstr(\"#{key}\"))"]
          nested_fields.each do |nf|
            inner.concat(field_load_lines(nf, nested_h, "#{target_path}.#{nf[:name]}"))
            if @broken
              return []
            end
          end
          @ctx[:struct_visited].delete(nested_type)
          inner
        else
          mark_broken
          []
        end
      end

      def mark_broken
        @broken = true
        nil
      end

      def struct_type(type_str)
        type_str.sub(/\s*\*.*\z/, "").gsub(/\b_(Nonnull|Nullable)\b/, "").sub(/\Aconst\s+/, "").strip
      end

      def strip_annotations(type_str)
        type_str.gsub(/\b_(Nonnull|Nullable)\b/, "").strip
      end
    end
    Marshaller::REGISTRY["struct_in"] = StructInMarshaller

    class StructOutMarshaller < Marshaller
      def initialize(param, index, ctx)
        super
        @broken = false
        @fields = load_fields
      end

      def broken?; @broken; end

      def out_handling
        {
          init:    "var #{@param[:name]}_struct = #{type}()",
          addr:    "&#{@param[:name]}_struct",
          to_ruby: "#{@param[:name]}_h"
        }
      end

      def out_post_call
        return nil if @broken
        h_var = "#{@param[:name]}_h"
        lines = ["let #{h_var} = rb_hash_new()"]
        @fields.each do |f|
          val_expr = field_to_ruby(f, "#{@param[:name]}_struct.#{f[:name]}")
          if val_expr.nil?
            @broken = true
            return nil
          end
          lines << "rb_hash_aset(#{h_var}, rb_str_new_cstr(\"#{f[:name]}\"), #{val_expr})"
        end
        lines.join("\n    ")
      end

      private

      def type
        @param[:type].sub(/\s*\*.*\z/, "").gsub(/\b_(Nonnull|Nullable)\b/, "").sub(/\Aconst\s+/, "").strip
      end

      def load_fields
        return @broken = true unless @ctx[:knowledge_cache]
        sym = @ctx[:knowledge_cache].lookup_symbol(framework: @ctx[:framework], symbol: type)
        unless sym && sym[:fields_json]
          @broken = true
          return []
        end
        JSON.parse(sym[:fields_json], symbolize_names: true)
      end

      def field_to_ruby(field, swift_path)
        case field[:kind]
        when "int"        then "rb_ll2inum(Int64(#{swift_path}))"
        when "float"      then "rb_float_new(Double(#{swift_path}))"
        when "bool"       then "(#{swift_path} ? Qtrue : Qfalse)"
        when "opaque_ref" then "rb_ull2inum(UInt64(#{swift_path}))"
        else nil
        end
      end
    end
    Marshaller::REGISTRY["struct_out"] = StructOutMarshaller

    class StructInPointerMarshaller < Marshaller
      def initialize(param, index, ctx)
        super
        @fields = load_fields
        @use_hash_path = !@fields.nil? && !@fields.empty?
      end

      def in_load
        type = struct_type(@param[:type])
        name = @param[:name]; i = @index
        if @use_hash_path
          lines = ["let #{name}_h = argv[#{i}]", "var #{name}_struct = #{type}()"]
          @fields.each do |f|
            case f[:kind]
            when "int"
              lines << "#{name}_struct.#{f[:name]} = #{strip_annotations(f[:type])}(rb_num2ll(rb_hash_aref(#{name}_h, rb_str_new_cstr(\"#{f[:name]}\"))))"
            when "float"
              lines << "#{name}_struct.#{f[:name]} = rb_num2dbl(rb_hash_aref(#{name}_h, rb_str_new_cstr(\"#{f[:name]}\"))) "
            when "bool"
              lines << "#{name}_struct.#{f[:name]} = (rb_hash_aref(#{name}_h, rb_str_new_cstr(\"#{f[:name]}\")) != Qfalse)"
            end
          end
          lines.join("\n    ")
        else
          "let #{name}: UnsafePointer<#{type}> = UnsafePointer<#{type}>(bitPattern: UInt(rb_num2ull(argv[#{i}])))!"
        end
      end

      def call_arg
        @use_hash_path ? "&#{@param[:name]}_struct" : @param[:name]
      end

      private

      def load_fields
        return nil unless @ctx[:knowledge_cache]
        type = struct_type(@param[:type])
        sym = @ctx[:knowledge_cache].lookup_symbol(framework: @ctx[:framework], symbol: type)
        return nil unless sym && sym[:fields_json]
        JSON.parse(sym[:fields_json], symbolize_names: true)
      end

      def struct_type(type_str)
        type_str
          .sub(/\Aconst\s+/, "")
          .sub(/\s*\*.*\z/, "")
          .gsub(/\b_(Nonnull|Nullable)\b/, "")
          .strip
      end

      def strip_annotations(type_str)
        type_str.gsub(/\b_(Nonnull|Nullable)\b/, "").strip
      end
    end
    Marshaller::REGISTRY["struct_in_pointer"] = StructInPointerMarshaller

    class VariadicMarshaller < Marshaller
      def in_load
        i = @index
        <<~SWIFT.chomp
          var __cVarArgs: [CVarArg] = []
              for __k in #{i}..<Int(argc) {
                  __cVarArgs.append(rubyValueToCVarArg(argv[__k]))
              }
        SWIFT
      end

      def call_arg
        "__va"
      end
    end
    Marshaller::REGISTRY["variadic_args"] = VariadicMarshaller
  end
end
