# frozen_string_literal: true

module AppleSDKKnowledge
  module Importer
    module Kind
      module_function

      def classify_kind(qual_type, desugared = qual_type, nullability = "unspecified")
        is_function_pointer = desugared.include?("(") && desugared.include?(")")
        is_void_ptr = qual_type =~ /\bvoid\s*\*/
        combined = qual_type == desugared ? qual_type : "#{qual_type} #{desugared}"
        treat_nilable = (nullability == "nullable" || nullability == "unspecified")

        if is_void_ptr
          return "void_ptr_nilable" if treat_nilable
          return "unsupported"
        end

        if is_function_pointer
          return "callback_nilable" if treat_nilable
          return "callback_non_nil"
        end

        return "string" if qual_type =~ /\b(CFStringRef|NSString\s*\*|char\s*\*|const\s+char\s*\*)/
        return "bool"   if combined =~ /\b(_Bool|Bool|BOOL|bool)\b/
        return "float"  if combined =~ /\b(double|float|CGFloat|CFAbsoluteTime|CFTimeInterval|NSTimeInterval|TimeInterval)\b/
        if combined =~ /\b(?:int|U?Int(?:8|16|32|64)?|SInt(?:8|16|32|64)?|long|short|unsigned|signed|uint(?:8|16|32|64)_t|int(?:8|16|32|64)_t|OSStatus|kern_return_t)\b/
          return "opaque_ref" if qual_type =~ /\b\w+Ref\b/
          return "int"
        end
        return "cftype_ref" if qual_type =~ /\b(?:CF|CG|CV|CT|CM|CL|IO|Sec|AX)\w+Ref\b/
        return "opaque_ref" if qual_type =~ /\b\w+Ref\b/
        return "struct_in_pointer" if qual_type =~ /\bconst\s+\w+\s*\*/
        "unsupported"
      end

      def out_param?(qual_type, name, is_last_pointer)
        return false unless qual_type.include?("*")
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
