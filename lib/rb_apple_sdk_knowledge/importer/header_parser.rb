# frozen_string_literal: true
require "open3"
require "json"

module AppleSDKKnowledge
  module Importer
    class HeaderParser
      def parse_file(path)
        json = run_clang_ast_dump(path)
        symbols = []
        # Top-level siblings before any explicit `loc.file` are compiler-builtin
        # types (__builtin_va_list etc.) — initialize inherited file as nil so
        # they are skipped, and let the first explicit marker set the context.
        walk(json["inner"], nil, path, symbols)
        symbols
      end

      private

      def run_clang_ast_dump(path)
        out, err, status = Open3.capture3(
          "clang", "-Xclang", "-ast-dump=json", "-fsyntax-only",
          "-x", "c", path
        )
        raise "clang failed for #{path}: #{err.strip}" unless status.success?
        JSON.parse(out)
      rescue JSON::ParserError => e
        raise "clang produced invalid JSON for #{path}: #{e.message}"
      end

      # Walks AST sibling lists and only emits symbols whose source location
      # matches `target`. clang's JSON loc inherits across siblings: a node
      # without an explicit `file` keeps the file of the previous sibling.
      def walk(siblings, parent_file, target, symbols)
        current_file = parent_file
        (siblings || []).each do |node|
          next unless node.is_a?(Hash)
          f = resolve_file(node)
          current_file = f if f
          emit_symbol(node, symbols) if current_file == target
          walk(node["inner"], current_file, target, symbols)
        end
      end

      def resolve_file(node)
        loc = node["loc"] || {}
        return loc["file"] if loc["file"]
        return loc.dig("expansionLoc", "file") if loc.dig("expansionLoc", "file")
        rb = node.dig("range", "begin") || {}
        return rb["file"] if rb["file"]
        rb.dig("expansionLoc", "file")
      end

      def emit_symbol(node, symbols)
        case node["kind"]
        when "FunctionDecl"
          if node["storageClass"] != "static"
            symbols << {
              name: node["name"],
              kind: "function",
              abi: "c",
              parent_name: nil,
              signature: function_signature(node),
              return_type: node.dig("type", "qualType"),
              parameters: function_parameters(node)
            }
          end
        when "RecordDecl"
          if node["name"]
            symbols << {
              name: node["name"],
              kind: "struct",
              abi: "c",
              parent_name: nil,
              signature: "struct #{node['name']}"
            }
          end
        when "TypedefDecl"
          name = node["name"]
          underlying = node.dig("type", "qualType") || ""
          function_pointer = underlying.include?("(*)") || underlying.include?("(^)")
          if !function_pointer && (underlying.include?("struct ") || underlying.include?("*"))
            symbols << {
              name: name,
              kind: "struct",
              abi: "c",
              parent_name: nil,
              signature: "typedef #{underlying} #{name}"
            }
          end
        when "EnumDecl"
          (node["inner"] || []).each do |child|
            if child["kind"] == "EnumConstantDecl"
              symbols << {
                name: child["name"],
                kind: "global_constant",
                abi: "c",
                parent_name: nil,
                signature: "enum case #{child['name']}"
              }
            end
          end
        when "VarDecl"
          if node["storageClass"] == "extern" || node.dig("type", "qualType")&.include?("const")
            symbols << {
              name: node["name"],
              kind: "global_constant",
              abi: "c",
              parent_name: nil,
              signature: "extern #{node.dig('type', 'qualType')} #{node['name']}"
            }
          end
        end
      end

      def function_signature(node)
        return_type = node.dig("type", "qualType") || ""
        params = (node["inner"] || []).select { |i| i["kind"] == "ParmVarDecl" }
        param_str = params.map { |p| "#{p.dig('type', 'qualType')} #{p['name']}" }.join(", ")
        "#{return_type.split(" (").first} #{node['name']}(#{param_str})"
      end

      def function_parameters(node)
        params = (node["inner"] || []).select { |i| i["kind"] == "ParmVarDecl" }
        pointer_params = params.select { |p| (p.dig("type", "qualType") || "").include?("*") }
        last_pointer = pointer_params.last

        params.each_with_index.map do |p, i|
          qual_type = p.dig("type", "qualType") || ""
          name = p["name"] || "_arg#{i}"
          {
            name: name,
            type: qual_type,
            kind: classify_kind(qual_type),
            is_out_param: out_param?(qual_type, name, p == last_pointer),
            nullability: nullability_of(qual_type)
          }
        end
      end

      def classify_kind(qual_type)
        return "string" if qual_type =~ /\b(CFStringRef|NSString\s*\*|char\s*\*|const\s+char\s*\*)/
        return "bool"   if qual_type =~ /\b(_Bool|Bool|BOOL)\b/
        return "float"  if qual_type =~ /\b(double|float|CGFloat)\b/
        if qual_type =~ /\b(?:U?Int(?:8|16|32|64)?|SInt(?:8|16|32|64)?|long|short|unsigned|signed|uint(?:8|16|32|64)_t|int(?:8|16|32|64)_t|OSStatus|kern_return_t)\b/
          return "opaque_ref" if qual_type =~ /\b\w+Ref\b/
          return "int"
        end
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
