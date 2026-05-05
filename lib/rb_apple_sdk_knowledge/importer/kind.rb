# frozen_string_literal: true

module AppleSDKKnowledge
  module Importer
    module Kind
      module_function

      def classify_kind(qual_type, desugared = qual_type)
        # Function-pointer typedefs surface as `void (*)(...)` etc. in desugaredQualType
        return "unsupported" if desugared.include?("(") && desugared.include?(")")
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
        return "unsupported" if qual_type =~ /\bvoid\s*\*/
        "unsupported"
      end

      def out_param?(qual_type, name, is_last_pointer)
        return false unless qual_type.include?("*")
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
