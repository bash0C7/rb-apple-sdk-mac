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
        # Top-level siblings before any explicit `loc.file` are compiler-builtin
        # types (__builtin_va_list etc.) — initialize inherited file as nil so
        # they are skipped, and let the first explicit marker set the context.
        walk(json["inner"], nil, path, symbols, nil)
        symbols
      end

      private

      def sdk_path
        @sdk_path ||= `xcrun --show-sdk-path`.strip
      end

      def run_clang_ast_dump(path)
        out, err, status = Open3.capture3(
          "clang", "-Xclang", "-ast-dump=json", "-fsyntax-only",
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

      # Walks AST sibling lists and only emits symbols whose source location
      # matches `target`. clang's JSON loc inherits across siblings: a node
      # without an explicit `file` keeps the file of the previous sibling.
      # `parent_objc` carries the enclosing ObjCInterfaceDecl / ObjCProtocolDecl
      # / ObjCCategoryDecl name down into ObjCMethodDecl / ObjCPropertyDecl
      # so method rows know their owning class.
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
            # clang AST exposes `instance: true|false` on ObjCMethodDecl.
            # `-` form methods carry instance=true; `+` form class methods
            # carry instance=false. Phase 2 dispatch routes class methods
            # to the metaclass call site, so the kind column must reflect
            # this distinction at import time instead of forcing every
            # method to instance_method.
            is_instance = node["instance"] != false
            symbols << {
              name: node["name"],
              kind: is_instance ? "instance_method" : "class_method",
              abi: "objc",
              parent_name: parent_objc,
              signature: objc_method_signature(node, is_instance: is_instance),
              return_type: node.dig("returnType", "qualType"),
              parameters: function_parameters(node),
              documentation: extract_documentation(node)
            }
          end
        when "FunctionDecl"
          if node["storageClass"] != "static"
            symbols << {
              name: node["name"],
              kind: "function",
              abi: "c",
              parent_name: nil,
              signature: function_signature(node),
              return_type: node.dig("type", "qualType"),
              parameters: function_parameters(node),
              documentation: extract_documentation(node)
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

      # Flattens clang's FullComment subtree into a single doc string.
      # Returns nil when the declaration carries no doc comment.
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
            # Phase 1 T3: surface nullability as a Ruby/JSON boolean for
            # emitters that need a binary "use nilable marshaller?" gate
            # without re-parsing the string form. nil ↔ unspecified.
            nullable: parameter_nullable(qual_type)
          }
        end
      end

      def parameter_nullable(qual_type)
        return true  if qual_type.match?(/_Nullable\b/)
        return false if qual_type.match?(/_Nonnull\b/)
        nil
      end

      def objc_method_signature(node, is_instance: true)
        return_type = node.dig("returnType", "qualType") || "void"
        prefix = is_instance ? "-" : "+"
        "#{prefix} (#{return_type}) #{node['name']}"
      end
    end
  end
end
