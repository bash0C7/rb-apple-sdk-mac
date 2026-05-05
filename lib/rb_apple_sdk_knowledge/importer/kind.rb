# frozen_string_literal: true

module AppleSDKKnowledge
  module Importer
    module Kind
      module_function

      def classify_kind(qual_type, desugared = qual_type, nullability = "unspecified")
        is_function_pointer = desugared.include?("(") && desugared.include?(")")
        is_void_ptr = qual_type =~ /\bvoid\s*\*/
        # Unspecified nullability is treated as nilable (safe default — older
        # headers without _Nullable annotations still get the nilable
        # Marshaller, which handles Qnil correctly).
        treat_nilable = (nullability == "nullable" || nullability == "unspecified")

        if is_void_ptr
          return "void_ptr_nilable" if treat_nilable
          return "unsupported"
        end

        if is_function_pointer
          return "callback_nilable" if treat_nilable
          return "callback_non_nil"
        end

        # Apple naming-convention fallback: typedefs ending in Proc/Callback/
        # Handler/Func/Routine are function pointers. The reclassifier path has
        # no access to clang's desugared form, so the parens-detection above
        # never fires; this fallback recovers callback kinds in that case.
        normalized = qual_type.gsub(/\b_(Nonnull|Nullable)\b/, "").strip
        if normalized =~ /\b\w+(?:Proc|Callback|CallBack|Handler|Routine)\b/
          return "callback_nilable" if treat_nilable
          return "callback_non_nil"
        end

        return "string" if qual_type =~ /\b(CFStringRef|NSString\s*\*|char\s*\*|const\s+char\s*\*)/
        return "bool"   if qual_type =~ /\b(_Bool|Bool|BOOL|bool)\b/
        return "float"  if qual_type =~ /\b(double|float|CGFloat)\b/
        if qual_type =~ /\b(?:int|U?Int(?:8|16|32|64)?|SInt(?:8|16|32|64)?|long|short|unsigned|signed|uint(?:8|16|32|64)_t|int(?:8|16|32|64)_t|OSStatus|kern_return_t)\b/
          return "opaque_ref" if qual_type =~ /\b\w+Ref\b/
          return "int"
        end
        # Struct pointer typedefs ending in Ref (e.g. MiniClientRef, CGContextRef) —
        # treated as opaque handles regardless of underlying integer-vs-pointer shape.
        return "opaque_ref" if qual_type =~ /\b\w+Ref\b/
        # `const SomeStruct *` (read-only struct pointer) — Ruby user passes
        # a UInt encoding a pointer (commonly built via Fiddle); the Marshaller
        # casts to UnsafePointer<SomeStruct> at the C call site.
        return "struct_in_pointer" if qual_type =~ /\bconst\s+\w+\s*\*/
        "unsupported"
      end

      def out_param?(qual_type, name, is_last_pointer)
        return false unless qual_type.include?("*")
        # `const T *` is read-only input; never an out-param even when it
        # happens to be the last pointer in the signature.
        return false if qual_type =~ /\bconst\s+\w+\s*\*/
        is_last_pointer || name.start_with?("out")
      end

      def nullability_of(qual_type)
        return "nonnull"  if qual_type.include?("_Nonnull")
        return "nullable" if qual_type.include?("_Nullable")
        "unspecified"
      end
    end
  end
end
