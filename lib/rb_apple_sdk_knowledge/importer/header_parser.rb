# frozen_string_literal: true
require "open3"
require "json"

module AppleSDKKnowledge
  module Importer
    class HeaderParser
      def parse_file(path)
        json = run_clang_ast_dump(path)
        extract_symbols(json)
      end

      private

      def run_clang_ast_dump(path)
        out, _err, status = Open3.capture3(
          "clang", "-Xclang", "-ast-dump=json", "-fsyntax-only",
          "-x", "c", path
        )
        raise "clang failed for #{path}" unless status.success?
        JSON.parse(out)
      rescue JSON::ParserError => e
        raise "clang produced invalid JSON for #{path}: #{e.message}"
      end

      def extract_symbols(node, symbols = [])
        return symbols unless node.is_a?(Hash)
        case node["kind"]
        when "FunctionDecl"
          if node["storageClass"] != "static"
            symbols << {
              name: node["name"],
              kind: "function",
              abi: "c",
              parent_name: nil,
              signature: function_signature(node),
              return_type: node.dig("type", "qualType")
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
          if underlying.include?("struct ") || underlying.include?("*")
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
        (node["inner"] || []).each { |child| extract_symbols(child, symbols) }
        symbols
      end

      def function_signature(node)
        return_type = node.dig("type", "qualType") || ""
        params = (node["inner"] || []).select { |i| i["kind"] == "ParmVarDecl" }
        param_str = params.map { |p| "#{p.dig('type', 'qualType')} #{p['name']}" }.join(", ")
        "#{return_type.split(" (").first} #{node['name']}(#{param_str})"
      end
    end
  end
end
