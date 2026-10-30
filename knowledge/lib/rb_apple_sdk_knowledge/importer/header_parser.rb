# frozen_string_literal: true
require "open3"
require "json"
require_relative "kind"

module AppleSDKKnowledge
  module Importer
    class HeaderParser
      def initialize(sdk_path: nil)
        @sdk_path = sdk_path
      end

      def parse_file(path)
        json = run_clang_ast_dump(path)
        symbols = []
        walk(json["inner"], nil, path, symbols, nil)
        scan_function_like_macros(path, symbols)
        symbols
      end

      private

      def sdk_path
        @sdk_path ||= `xcrun --show-sdk-path`.strip
      end

      def run_clang_ast_dump(path)
        out, err, status = Open3.capture3(
          "xcrun", "clang", "-Xclang", "-ast-dump=json", "-fsyntax-only",
          "-x", "objective-c",
          "-isysroot", sdk_path,
          "-F", File.join(sdk_path, "System", "Library", "Frameworks"),
          "-arch", "arm64",
          path
        )
        raise "clang failed for #{path}: #{err.strip}" unless status.success?
        JSON.parse(out)
      rescue JSON::ParserError => e
        raise "clang produced invalid JSON for #{path}: #{e.message}"
      end

      def walk(siblings, parent_file, target, symbols, parent_objc)
        current_file = parent_file
        (siblings || []).each do |node|
          next unless node.is_a?(Hash)
          f = resolve_file(node)
          current_file = f if f
          emit_symbol(node, symbols, parent_objc) if current_file == target
          child_parent_objc = case node["kind"]
                              when "ObjCInterfaceDecl", "ObjCProtocolDecl", "ObjCCategoryDecl"
                                node["name"] || parent_objc
                              else
                                parent_objc
                              end
          walk(node["inner"], current_file, target, symbols, child_parent_objc)
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

      def emit_symbol(node, symbols, parent_objc = nil)
        case node["kind"]
        when "ObjCMethodDecl"
          if node["name"]
            is_instance = node["instance"] != false
            cb_sig = extract_first_block_signature(node)
            symbols << {
              name: node["name"],
              kind: is_instance ? "instance_method" : "class_method",
              abi: "objc",
              parent_name: parent_objc,
              signature: objc_method_signature(node, is_instance: is_instance),
              return_type: node.dig("returnType", "qualType"),
              parameters: function_parameters(node),
              documentation: extract_documentation(node),
              return_ownership: returns_retained?(node) ? "retained" : nil,
              callback_signature_json: cb_sig && JSON.generate(cb_sig)
            }
          end
        when "FunctionDecl"
          if node["storageClass"] != "static" || inline_only_function?(node)
            symbols << {
              name: node["name"],
              kind: "function",
              abi: "c",
              parent_name: nil,
              signature: function_signature(node),
              return_type: node.dig("type", "qualType"),
              parameters: function_parameters(node),
              documentation: extract_documentation(node),
              return_ownership: returns_retained?(node) ? "retained" : nil,
              unsupported_pattern: inline_only_function?(node) ? "inline_only" : nil
            }
          end
        when "RecordDecl"
          if node["name"]
            fields = (node["inner"] || []).select { |c| c["kind"] == "FieldDecl" }.map do |fd|
              qt = fd.dig("type", "qualType") || ""
              desugared = fd.dig("type", "desugaredQualType") || qt
              nullability = Kind.nullability_of(qt)
              {
                name: fd["name"],
                type: qt,
                kind: Kind.classify_kind(qt, desugared, nullability)
              }
            end
            symbols << {
              name: node["name"],
              kind: "struct",
              abi: "c",
              parent_name: nil,
              signature: "struct #{node['name']}",
              fields: fields,
              documentation: extract_documentation(node)
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
              signature: "typedef #{underlying} #{name}",
              documentation: extract_documentation(node)
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
                signature: "enum case #{child['name']}",
                documentation: extract_documentation(child)
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
              signature: "extern #{node.dig('type', 'qualType')} #{node['name']}",
              documentation: extract_documentation(node)
            }
          end
        end
      end

      def extract_documentation(node)
        full = (node["inner"] || []).find { |c| c.is_a?(Hash) && c["kind"] == "FullComment" }
        return nil unless full
        texts = []
        collect_text_nodes(full, texts)
        flattened = texts.map(&:strip).reject(&:empty?).join(" ").strip
        flattened.empty? ? nil : flattened
      end

      def collect_text_nodes(node, accum)
        return unless node.is_a?(Hash)
        if node["kind"] == "TextComment" && node["text"]
          accum << node["text"]
        end
        (node["inner"] || []).each { |child| collect_text_nodes(child, accum) }
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
          desugared = p.dig("type", "desugaredQualType") || qual_type
          name = p["name"] || "_arg#{i}"
          nullability = Kind.nullability_of(qual_type)
          {
            name: name,
            type: qual_type,
            kind: Kind.classify_kind(qual_type, desugared, nullability),
            is_out_param: Kind.out_param?(qual_type, name, p == last_pointer),
            nullability: nullability,
            nullable: parameter_nullable(qual_type)
          }
        end
      end

      def parameter_nullable(qual_type)
        return true  if qual_type.match?(/_Nullable\b/)
        return false if qual_type.match?(/_Nonnull\b/)
        nil
      end

      def extract_first_block_signature(node)
        params = (node["inner"] || []).select { |i| i["kind"] == "ParmVarDecl" }
        params.each do |p|
          qt = p.dig("type", "qualType") || ""
          next unless qt.include?("(^")
          sig = extract_block_signature_from_qualtype(qt)
          return sig if sig
        end
        nil
      end

      def extract_block_signature_from_qualtype(qual_type)
        m = qual_type.match(/\A([^\(]+?)\s*\(\^(?:\s*_Nullable|\s*_Nonnull)?\)\s*\(([^)]*)\)\z/)
        return nil unless m
        return_type = simple_type_name(m[1])
        args_str = m[2].strip
        args =
          if args_str.empty? || args_str == "void"
            []
          else
            args_str.split(/,\s*/).map do |arg|
              nullable = arg.match?(/\b_Nullable\b/)
              type_clean = arg.sub(/\b_Nullable\b|\b_Nonnull\b/, "").strip
              { type: simple_type_name(type_clean), nullable: nullable }
            end
          end
        { params: args, return_type: return_type }
      end

      def simple_type_name(s)
        s = s.to_s.sub(/\b_Nullable\b|\b_Nonnull\b/, "").strip
        return "Void" if s == "void"
        s.sub(/\s*\*+\s*\z/, "").strip
      end

      def returns_retained?(node)
        (node["inner"] || []).any? do |child|
          next false unless child.is_a?(Hash)
          kind = child["kind"].to_s
          kind == "CFReturnsRetainedAttr" || kind == "NSReturnsRetainedAttr"
        end
      end

      def inline_only_function?(node)
        return false unless node["kind"] == "FunctionDecl"
        return false unless node["inline"] == true
        node["storageClass"] == "static"
      end

      def scan_function_like_macros(path, symbols)
        File.foreach(path) do |line|
          m = line.match(/^\s*#\s*define\s+([A-Za-z_][A-Za-z0-9_]*)\(([^)]*)\)/)
          next unless m
          name = m[1]
          params_str = m[2].strip
          param_names =
            if params_str.empty?
              []
            else
              params_str.split(/,\s*/).map(&:strip).reject(&:empty?)
            end
          symbols << {
            name: name,
            kind: "function",
            abi: "c",
            parent_name: nil,
            signature: "#define #{name}(#{param_names.join(', ')})",
            return_type: nil,
            parameters: param_names.each_with_index.map { |pn, i|
              { name: pn.empty? ? "_arg#{i}" : pn, type: nil, kind: "opaque", is_out_param: false, nullability: nil, nullable: nil }
            },
            documentation: nil,
            return_ownership: nil,
            unsupported_pattern: "function_macro"
          }
        end
      end

      def objc_method_signature(node, is_instance: true)
        return_type = node.dig("returnType", "qualType") || "void"
        prefix = is_instance ? "-" : "+"
        "#{prefix} (#{return_type}) #{node['name']}"
      end
    end
  end
end
