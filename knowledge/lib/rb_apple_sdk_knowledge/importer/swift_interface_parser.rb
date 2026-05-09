# frozen_string_literal: true

module AppleSDKKnowledge
  module Importer
    class SwiftInterfaceParser
      FUNC_RE   = /^public\s+(?:static\s+)?func\s+(\w+)\s*(\([^)]*\))\s*(->\s*[\w.<>\[\]?!,\s]+)?$/
      EXTENSION_RE = /^public\s+extension\s+(\w+)|^extension\s+(\w+)/
      CLASS_RE  = /^public\s+(?:final\s+)?class\s+(\w+)/
      STRUCT_RE = /^public\s+struct\s+(\w+)/
      ENUM_RE   = /^public\s+enum\s+(\w+)/
      PROTOCOL_RE = /^public\s+protocol\s+(\w+)/
      ACTOR_RE  = /^public\s+actor\s+(\w+)/
      INIT_RE   = /^\s+public\s+init\s*(\([^)]*\))/
      INSTANCE_METHOD_RE = /^\s+public\s+(?:override\s+)?func\s+(\w+)\s*(\([^)]*\))\s*(->\s*[\w.<>\[\]?!,\s]+)?$/
      VAR_RE    = /^\s+public\s+var\s+(\w+)\s*:\s*([\w.<>\[\]?!,\s]+)\s*\{\s*(get(?:\s+set)?)\s*\}/
      LET_RE    = /^\s+public\s+let\s+(\w+)\s*:\s*([\w.<>\[\]?!,\s]+)/
      ENUM_CASE_RE = /^\s+case\s+(\w+)/

      def parse_file(path)
        text = File.read(path)
        parse(text)
      end

      def parse(text)
        symbols = []
        current_parent = nil
        depth = 0

        text.each_line do |line|
          stripped = line.rstrip

          depth += stripped.count("{") - stripped.count("}")
          if depth == 0 && current_parent
            current_parent = nil
          end

          if (m = stripped.match(EXTENSION_RE))
            current_parent = m[1] || m[2]
          elsif (m = stripped.match(CLASS_RE))
            symbols << { name: m[1], kind: "class", abi: "swift", parent_name: nil, signature: stripped.strip }
            current_parent = m[1]
          elsif (m = stripped.match(STRUCT_RE))
            symbols << { name: m[1], kind: "struct", abi: "swift", parent_name: nil, signature: stripped.strip }
            current_parent = m[1]
          elsif (m = stripped.match(ENUM_RE))
            symbols << { name: m[1], kind: "enum_module", abi: "swift", parent_name: nil, signature: stripped.strip }
            current_parent = m[1]
          elsif (m = stripped.match(PROTOCOL_RE))
            symbols << { name: m[1], kind: "protocol", abi: "swift", parent_name: nil, signature: stripped.strip }
            current_parent = m[1]
          elsif (m = stripped.match(ACTOR_RE))
            symbols << { name: m[1], kind: "actor", abi: "swift", parent_name: nil, signature: stripped.strip }
            current_parent = m[1]
          elsif (m = stripped.match(FUNC_RE)) && current_parent.nil?
            symbols << { name: m[1], kind: "function", abi: "swift", parent_name: nil, signature: stripped.strip }
          elsif (m = stripped.match(INSTANCE_METHOD_RE)) && current_parent
            symbols << { name: m[1], kind: "instance_method", abi: "swift", parent_name: current_parent, signature: stripped.strip }
          elsif (m = stripped.match(VAR_RE)) && current_parent
            symbols << { name: m[1], kind: "instance_property", abi: "swift", parent_name: current_parent, signature: stripped.strip }
          elsif (m = stripped.match(LET_RE)) && current_parent
            symbols << { name: m[1], kind: "instance_property", abi: "swift", parent_name: current_parent, signature: stripped.strip }
          elsif (m = stripped.match(ENUM_CASE_RE)) && current_parent
            symbols << { name: m[1], kind: "enum_case", abi: "swift", parent_name: current_parent, signature: stripped.strip }
          elsif (m = stripped.match(INIT_RE)) && current_parent
            symbols << { name: "init", kind: "class_method", abi: "swift", parent_name: current_parent, signature: stripped.strip }
          end
        end

        symbols
      end
    end
  end
end
