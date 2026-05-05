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

      def in_load;     nil end
      def call_arg;    @param[:name] end
      def out_init;    nil end
      def out_addr;    nil end
      def out_to_ruby; nil end
      def call_wrapper(inner); inner end

      REGISTRY = {}

      def self.for(param, index, ctx)
        klass = REGISTRY[param[:kind]]
        return nil unless klass
        klass.new(param, index, ctx)
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
        @param[:is_out_param] ? "&outRef" : @param[:name]
      end

      def out_init
        return nil unless @param[:is_out_param]
        ref_type = strip_pointer(@param[:type])
        "var outRef: #{ref_type} = #{ref_type}()"
      end

      def out_addr
        return nil unless @param[:is_out_param]
        "&outRef"
      end

      def out_to_ruby
        return nil unless @param[:is_out_param]
        if unsigned?(@param[:type])
          "rb_ull2inum(UInt64(outRef))"
        else
          "rb_ll2inum(Int64(outRef))"
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

    class CallbackNilableMarshaller < Marshaller
      def in_load
        type = @param[:type].sub(/\s*_(?:Nullable|Nonnull)\b/, "").strip
        name = @param[:name]; i = @index
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
      def in_load
        type = @param[:type].sub(/\s*_(?:Nullable|Nonnull)\b/, "").strip
        name = @param[:name]
        # rb_raise is `-> Never`, so Swift accepts the let-binding as
        # definitely-assigned in the only non-terminating branch.
        <<~SWIFT.chomp
          let #{name}: #{type}?
              rb_raise(rb_eRuntimeError, "non-nil callback not yet supported")
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
  end
end
