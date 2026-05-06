# frozen_string_literal: true
require "set"

module AppleSDKMac
  class GlueCompiler
    # Each parameter kind is realized as a Marshaller. Subclasses implement the
    # subset of the protocol that applies to them; defaults below are no-ops.
    #
    # Protocol (each returns a Swift snippet or nil):
    #   in_load     — argv[i] → Swift binding at the function entry
    #   call_arg    — Swift expression for the argument at the C call site
    #   out_init    — out-param `var` declaration before the call
    #   out_addr    — `&...` expression at the call site for an out-param
    #   out_to_ruby — Swift expression that converts the post-call out value to Ruby VALUE
    #   call_wrapper(inner) — optional wrapping around the C call expression
    #                         (e.g. withUnsafePointer { ... }); base returns inner
    class Marshaller
      attr_reader :param, :index, :ctx

      def initialize(param, index, ctx)
        @param = param
        @index = index
        @ctx = ctx
      end

      def in_load;      nil end
      def call_arg;     @param[:name] end
      def out_init;     nil end
      def out_addr;     nil end
      def out_post_call; nil end  # Swift snippet between status check and return
      def out_to_ruby;  nil end   # final expression for `return ...`
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
        "let #{@param[:name]}: Int64 = rb_num2ll(argv[#{@index}])"
      end
    end
    Marshaller::REGISTRY["int"] = IntMarshaller

    class BoolMarshaller < Marshaller
      def in_load
        "let #{@param[:name]}: Bool = (argv[#{@index}] != Qfalse && argv[#{@index}] != Qnil)"
      end
    end
    Marshaller::REGISTRY["bool"] = BoolMarshaller

    class FloatMarshaller < Marshaller
      def in_load
        "let #{@param[:name]}: Double = rb_num2dbl(argv[#{@index}])"
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

      def out_init
        return nil unless @param[:is_out_param]
        ref_type = strip_pointer(@param[:type])
        "var #{@param[:name]}: #{ref_type} = #{ref_type}()"
      end

      def out_addr
        return nil unless @param[:is_out_param]
        "&#{@param[:name]}"
      end

      def out_to_ruby
        return nil unless @param[:is_out_param]
        if unsigned?(@param[:type])
          "rb_ull2inum(UInt64(#{@param[:name]}))"
        else
          "rb_ll2inum(Int64(#{@param[:name]}))"
        end
      end

      private

      def strip_pointer(t)
        t.sub(/\s*\*.*\z/, "").gsub(/\b_(Nonnull|Nullable)\b/, "").strip
      end

      def unsigned?(t)
        return true  if t.match?(/\b(UInt|UInt8|UInt16|UInt32|UInt64|uint(8|16|32|64)_t|unsigned)\b/)
        return false if t.match?(/\b(SInt|SInt8|SInt16|SInt32|SInt64|int(8|16|32|64)_t|signed)\b/)
        # Apple SDK convention: *Ref typedefs without explicit signedness marker
        # are unsigned 32-bit handles (MIDIClientRef, AudioComponentInstance, etc.).
        t.match?(/\b\w+Ref\b/)
      end
    end
    Marshaller::REGISTRY["opaque_ref"] = OpaqueRefMarshaller

    # CF/CG/CV/CT/CM/CL/IO/Sec/AX pointer-typed Refs. Underlying clang shape is
    # `struct OpaqueX *`, so the Ruby integer (a pointer bit-pattern) must round
    # trip via OpaquePointer(bitPattern:) and then unsafeBitCast to the real
    # Swift Ref type. The OpaqueRefMarshaller's `T(rb_num2ull(...))` path is
    # rejected by swiftc for these typedefs.
    class CFTypeRefMarshaller < Marshaller
      def in_load
        return nil if @param[:is_out_param]
        type = ref_type(@param[:type])
        "let #{@param[:name]} = unsafeBitCast(OpaquePointer(bitPattern: UInt(rb_num2ull(argv[#{@index}])))!, to: #{type}.self)"
      end

      def call_arg
        @param[:is_out_param] ? "&#{@param[:name]}" : @param[:name]
      end

      def out_init
        return nil unless @param[:is_out_param]
        type = ref_type(@param[:type])
        "var #{@param[:name]}: #{type}? = nil"
      end

      def out_addr
        return nil unless @param[:is_out_param]
        "&#{@param[:name]}"
      end

      def out_to_ruby
        return nil unless @param[:is_out_param]
        # Encode the CF pointer as Ruby Integer via the OpaquePointer raw bit-pattern.
        # User must CFRelease manually (no auto-ARC bridging in Phase 7).
        "rb_ull2inum(UInt64(UInt(bitPattern: unsafeBitCast(#{@param[:name]}!, to: OpaquePointer.self))))"
      end

      private

      def ref_type(t)
        t.sub(/\Aconst\s+/, "")
         .sub(/\s*\*.*\z/, "")
         .gsub(/\b_(Nonnull|Nullable)\b/, "")
         .strip
      end
    end
    Marshaller::REGISTRY["cftype_ref"] = CFTypeRefMarshaller

    # Callback type → CallbackPillar route. MVP catalog: MIDINotifyProc only.
    # Additional signatures are added by listing them in
    # ext/apple_sdk_mac_runtime/callback_signatures.yml + extending this map.
    CALLBACK_PILLAR_ROUTES = {
      "MIDINotifyProc" => :midi_notify
    }.freeze

    class CallbackNilableMarshaller < Marshaller
      def in_load
        type = @param[:type].sub(/\s*_(?:Nullable|Nonnull)\b/, "").strip
        name = @param[:name]; i = @index
        if (route = CALLBACK_PILLAR_ROUTES[type])
          register_branch(name, type, i, route)
        else
          legacy_branch(name, type, i)
        end
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
                  let #{name}_reg = rb_gv_get("$__apple_sdk_mac_proc_registry")
                  rb_hash_aset(#{name}_reg, #{name}_pid_v, argv[#{i}])
                  let #{name}_pid_u = rb_num2ull(#{name}_pid_v)
                  let #{name}_slot = #{fn_register}(#{name}_pid_u)
                  if #{name}_slot < 0 { rb_raise(rb_eRuntimeError, "callback slot pool exhausted") }
                  let #{name}_raw = #{fn_get_fnptr}(#{name}_slot)
                  #{name} = unsafeBitCast(UnsafeRawPointer(bitPattern: UInt(#{name}_raw))!, to: #{type}.self)
              }
        SWIFT
      end

      def legacy_branch(name, type, i)
        <<~SWIFT.chomp
          let #{name}: #{type}?
              if argv[#{i}] == Qnil {
                  #{name} = nil
              } else {
                  rb_raise(rb_eRuntimeError, "non-nil callback not yet supported")
              }
        SWIFT
      end
    end
    Marshaller::REGISTRY["callback_nilable"] = CallbackNilableMarshaller

    class CallbackNonNilMarshaller < Marshaller
      # Outside the catalog we cannot synthesize a real C function pointer
      # without crashing (the previous "let cb: T?; rb_raise(...)" stub was
      # rejected by swiftc because optional T? cannot be passed where the C
      # function expects T). Mark the marshaller as broken so the template
      # generator returns nil and the symbol falls through to LLM fallback
      # / unsupported. Catalog routes still produce real glue.
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
              let #{name}_reg = rb_gv_get("$__apple_sdk_mac_proc_registry")
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
        # Swift auto-promotes `&var` to UnsafePointer<T> / UnsafeMutablePointer<T>
        # for C function calls — no withUnsafePointer wrapper needed.
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

      def out_init
        "var #{@param[:name]}_struct = #{type}()"
      end

      def out_addr
        "&#{@param[:name]}_struct"
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

      def out_to_ruby
        "#{@param[:name]}_h"
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
      def in_load
        type = struct_type(@param[:type])
        name = @param[:name]; i = @index
        "let #{name}: UnsafePointer<#{type}> = UnsafePointer<#{type}>(bitPattern: UInt(rb_num2ull(argv[#{i}])))!"
      end

      private

      def struct_type(type_str)
        # Strip leading const, trailing *, nullability annotations.
        type_str
          .sub(/\Aconst\s+/, "")
          .sub(/\s*\*.*\z/, "")
          .gsub(/\b_(Nonnull|Nullable)\b/, "")
          .strip
      end
    end
    Marshaller::REGISTRY["struct_in_pointer"] = StructInPointerMarshaller

    class VariadicMarshaller < Marshaller
      def in_load
        i = @index
        # Build a [CVarArg] from the trailing argv entries beyond the fixed count.
        # `rubyValueToCVarArg` is provided by the runtime ext (CallbackPillar /
        # Marshal pillar helpers).
        <<~SWIFT.chomp
          var __cVarArgs: [CVarArg] = []
              for __k in #{i}..<Int(argc) {
                  __cVarArgs.append(rubyValueToCVarArg(argv[__k]))
              }
        SWIFT
      end

      def call_arg
        "__va"  # bound by withVaList wrapper in template_generator orchestrator
      end
    end
    Marshaller::REGISTRY["variadic_args"] = VariadicMarshaller
  end
end
