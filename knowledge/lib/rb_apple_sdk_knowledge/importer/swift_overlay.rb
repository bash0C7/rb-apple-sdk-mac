# frozen_string_literal: true
require "strscan"
require "digest"
require "json"

module AppleSDKKnowledge
  module Importer
    class SwiftOverlay
      EXTENSION_HEADER_RE = /\bextension\s+([A-Za-z_][\w.]*)[^{]*\{/.freeze

      DECL_FUNC_RE = /(?:open|public)\s+(?:(class|static)\s+)?func\s+(\w+)(?:<[^>]+>)?\s*\(([^)]*)\)((?:\s+(?:async|throws|rethrows))*)?(?:\s*->\s*([^\n{]+))?/.freeze

      DECL_INIT_RE = /(?:open|public)\s+(?:(convenience|required)\s+)?init(\??)\s*\(([^)]*)\)((?:\s+(?:throws|rethrows))*)?/.freeze

      DECL_VAR_RE = /(?:open|public)\s+(?:(class|static)\s+)?var\s+(\w+)\s*:\s*([^\n{]+?)(?:\s*\{\s*([^}]*)\})?\s*\z/.freeze

      DECL_ENUM_RE = /(?:open|public)\s+(?:indirect\s+)?enum\s+(\w+)(?:[^\n{]*)\{/.freeze

      CASE_RE = /^\s*case\s+([a-zA-Z_]\w*(?:\s*,\s*[a-zA-Z_]\w*)*)/.freeze

      DECL_CLASS_RE = /(?:open|public)\s+(?:final\s+)?class\s+(\w+)(?:[^\n{]*)\{/.freeze

      SWIFT_MACRO_ATTRS = %w[
        @Observable @attached @freestanding
      ].freeze

      SWIFT_RESULT_BUILDER_ATTRS = %w[
        @ViewBuilder @SceneBuilder @CommandsBuilder @ToolbarContentBuilder
        @RegexComponentBuilder
      ].freeze

      def initialize(store)
        @store = store
      end

      def self.framework_swiftinterface_paths(sdk_root)
        Dir.glob(
          File.join(sdk_root, "System/Library/Frameworks/*.framework/Modules/*.swiftmodule/*.swiftinterface")
        ).uniq
      end

      def extract_extension_blocks(source)
        scanner = StringScanner.new(source)
        blocks  = []

        until scanner.eos?
          if (m = scanner.scan_until(EXTENSION_HEADER_RE))
            dotted     = scanner.captures.first || m[/extension\s+([A-Za-z_][\w.]*)/, 1]
            klass      = dotted.split(".").last
            body_start = scanner.pos
            depth      = 1

            until scanner.eos? || depth == 0
              ch = scanner.getch
              case ch
              when "{" then depth += 1
              when "}" then depth -= 1
              end
            end

            body_end = depth == 0 ? scanner.pos - 1 : scanner.pos
            body     = source[body_start...body_end]
            blocks << { klass: klass, body: body }
          else
            break
          end
        end

        blocks
      end

      def extract_enum_blocks(source)
        scanner = StringScanner.new(source)
        blocks  = []

        until scanner.eos?
          if scanner.scan_until(DECL_ENUM_RE)
            name       = scanner.captures.first
            body_start = scanner.pos
            depth      = 1

            until scanner.eos? || depth == 0
              ch = scanner.getch
              case ch
              when "{" then depth += 1
              when "}" then depth -= 1
              end
            end

            body_end = depth == 0 ? scanner.pos - 1 : scanner.pos
            body     = source[body_start...body_end]
            blocks << { name: name, cases: parse_case_names(body) }
          else
            break
          end
        end

        blocks
      end

      def extract_class_blocks(source)
        scanner = StringScanner.new(source)
        blocks  = []

        until scanner.eos?
          if scanner.scan_until(DECL_CLASS_RE)
            name = scanner.captures.first
            attrs = preceding_attrs_for(scanner.pre_match)

            body_start = scanner.pos
            depth      = 1

            until scanner.eos? || depth == 0
              ch = scanner.getch
              case ch
              when "{" then depth += 1
              when "}" then depth -= 1
              end
            end

            body_end = depth == 0 ? scanner.pos - 1 : scanner.pos
            body     = source[body_start...body_end]
            blocks << { name: name, body: body, attrs: attrs }
          else
            break
          end
        end

        blocks
      end

      def preceding_attrs_for(text)
        return [] if text.nil? || text.empty?
        attrs = []
        text.lines.reverse_each do |raw|
          stripped = raw.strip
          next if stripped.empty?
          break unless stripped.start_with?("@")
          next if stripped.start_with?("@_")
          attrs.unshift(stripped)
        end
        attrs
      end

      def split_inline_attr(line)
        if (m = line.match(/\A(@\w+(?:\([^)]*\))?)\s*(.*)\z/))
          rest = m[2].strip
          [m[1], rest.empty? ? nil : rest]
        else
          [nil, line]
        end
      end

      def detect_unsupported(attrs)
        return nil if attrs.nil? || attrs.empty?
        attr_heads = attrs.map { |line| line.strip.split(/[\s(]/, 2).first }.compact
        return "swift_macro"    if attr_heads.any? { |a| SWIFT_MACRO_ATTRS.include?(a) }
        return "result_builder" if attr_heads.any? { |a| SWIFT_RESULT_BUILDER_ATTRS.include?(a) }
        nil
      end

      def parse_case_names(body)
        names = []
        body.scan(CASE_RE) do |m|
          m[0].split(",").map(&:strip).each { |c| names << c unless c.empty? }
        end
        names
      end

      def parse_decl_line(line)
        stripped = line.strip

        if (m = stripped.match(DECL_FUNC_RE))
          is_class = !m[1].nil?
          name     = m[2]
          params   = parse_params(m[3])
          effects  = (m[4] || "").strip
          ret      = m[5]&.strip
          kind     = is_class ? :class_func : :instance_func
          { kind: kind, name: name, params: params, return_type: ret,
            throws: effects.include?("throws"),
            async:  effects.include?("async"),
            failable: false,
            signature: stripped }

        elsif (m = stripped.match(DECL_INIT_RE))
          failable = m[2] == "?"
          params   = parse_params(m[3])
          effects  = (m[4] || "").strip
          { kind: :init, name: "init", params: params, return_type: nil,
            throws: effects.include?("throws"),
            async:  false,
            failable: failable,
            signature: stripped }

        elsif (m = stripped.match(DECL_VAR_RE))
          is_class = !m[1].nil?
          kind     = is_class ? :class_var : :instance_var
          accessor = m[4]
          settable = accessor.nil? ? true : accessor.include?("set")
          { kind: kind, name: m[2], params: [], return_type: m[3].strip,
            throws: false, async: false, failable: false,
            settable: settable,
            signature: stripped }

        else
          nil
        end
      end

      def parse_params(raw)
        return [] if raw.nil? || raw.strip.empty?

        raw.split(",").filter_map do |part|
          part = part.strip
          next nil if part.empty?

          if (m = part.match(/\A(\w+|\?|_)\s+(\w+)\s*:\s*(.+?)(?:\s*=\s*(.+?))?\s*\z/))
            external = m[1]
            internal = m[2]
            external_label = external == "_" ? nil : external
            type_clean = m[3].strip
            { label: m[1], internal: internal, type: type_clean,
              external_label: external_label, internal_name: internal,
              nullable: nullable_outer?(type_clean),
              default_value: extract_default_value(m[4]) }
          elsif (m = part.match(/\A(\w+)\s*:\s*(.+?)(?:\s*=\s*(.+?))?\s*\z/))
            name = m[1]
            type_clean = m[2].strip
            { label: name, internal: name, type: type_clean,
              external_label: name, internal_name: name,
              nullable: nullable_outer?(type_clean),
              default_value: extract_default_value(m[3]) }
          else
            nil
          end
        end
      end

      LITERAL_DEFAULT_RE = /\A(?:
        -?\d+(?:\.\d+)?           # numeric literal
        | "[^"]*"                 # string literal (no escaped-quote handling — Apple overlay literals are plain ASCII)
        | \.\w+                   # dot-prefixed enum case
        | true | false | nil
      )\z/x.freeze

      def extract_default_value(raw)
        return nil if raw.nil?
        stripped = raw.strip
        return nil if stripped.empty?
        LITERAL_DEFAULT_RE.match?(stripped) ? stripped : nil
      end

      def nullable_outer?(type)
        s = type.to_s.strip
        return false if s.empty?
        depth = 0
        s.each_char do |c|
          case c
          when "(", "[", "<" then depth += 1
          when ")", "]", ">" then depth -= 1
          end
        end
        return false unless depth == 0
        s.end_with?("?", "!")
      end

      def objc_selector_for(klass, decl)
        case decl[:kind]
        when :class_func, :instance_func
          params = decl[:params]
          if params.empty?
            decl[:name]
          else
            first, *rest = params
            suffix = first_param_suffix(first)
            head   = "#{decl[:name]}#{suffix}:"
            tail   = rest.map { |p| rest_param_part(p) }.join
            head + tail
          end

        when :init
          params = decl[:params]
          return "init" if params.empty?

          first, *rest = params
          suffix = first_param_with_suffix(first)
          head   = "initWith#{suffix}:"
          tail   = rest.map { |p| rest_param_part(p) }.join
          head + tail

        when :instance_var, :class_var
          decl[:name]

        else
          nil
        end
      end

      def swift_imported_name_for(decl)
        case decl[:kind]
        when :class_func, :instance_func
          params = decl[:params]
          if params.empty?
            "#{decl[:name]}()"
          else
            labels = params.map { |p| "#{p[:label]}:" }.join
            "#{decl[:name]}(#{labels})"
          end

        when :init
          params = decl[:params]
          if params.empty?
            "init()"
          else
            labels = params.map { |p| "#{p[:label]}:" }.join
            "init(#{labels})"
          end

        when :instance_var, :class_var
          decl[:name]

        else
          nil
        end
      end

      def import!(framework:, path:)
        source = File.read(path).gsub("::", ".")
        fw_id  = upsert_framework(framework)

        extract_extension_blocks(source).each do |block|
          klass_id = upsert_klass(block[:klass], fw_id)

          block[:body].each_line do |raw_line|
            line = raw_line.strip
            next if line.empty? || line.start_with?("//", "@_")

            decl = parse_decl_line(line)
            next unless decl

            upsert_decl(decl, klass: block[:klass], klass_id: klass_id, fw_id: fw_id)
          end
        end

        extract_enum_blocks(source).each do |enum_block|
          upsert_enum(enum_block, fw_id: fw_id)
        end

        extract_class_blocks(source).each do |class_block|
          class_marker = detect_unsupported(class_block[:attrs])
          klass_id = upsert_klass(class_block[:name], fw_id,
                                  unsupported_pattern: class_marker)

          pending_attrs = []
          class_block[:body].each_line do |raw_line|
            line = raw_line.strip
            next if line.empty? || line.start_with?("//")

            if line.start_with?("@_")
              next
            elsif line.start_with?("@")
              head, rest = split_inline_attr(line)
              pending_attrs << head if head
              if rest.nil? || rest.empty?
                next
              end
              line = rest
            end

            decl = parse_decl_line(line)
            unless decl
              pending_attrs.clear
              next
            end

            decl_marker = detect_unsupported(pending_attrs)
            pending_attrs.clear
            upsert_decl(decl, klass: class_block[:name], klass_id: klass_id,
                              fw_id: fw_id, unsupported_pattern: decl_marker)
          end
        end
      end

      private

      def capitalize(str)
        return str if str.empty?
        str[0].upcase + str[1..]
      end

      def first_param_suffix(param)
        label    = param[:label]
        internal = param[:internal]
        if label == "_"
          ""
        elsif label == internal
          capitalize(label)
        else
          "With#{capitalize(internal)}"
        end
      end

      def first_param_with_suffix(param)
        capitalize(param[:internal])
      end

      def rest_param_part(param)
        param[:label] == "_" ? ":" : "#{param[:label]}:"
      end

      def upsert_framework(name)
        existing = @store.find_framework_id_by_name(name)
        return existing if existing

        @store.insert_framework(name: name, swift_module: name, category: "swift_overlay")
      end

      def upsert_enum(enum_block, fw_id:)
        name  = enum_block[:name]
        cases = enum_block[:cases]
        hash  = Digest::SHA256.hexdigest("#{fw_id}|#{name}|enum|swift_overlay")

        @store.insert_symbol(
          framework_id:    fw_id,
          name:            name,
          kind:            "enum",
          abi:             "swift",
          content_hash:    hash,
          signature:       "enum #{name}",
          enum_cases_json: cases.empty? ? nil : JSON.generate(cases)
        )
      end

      def upsert_klass(klass_name, fw_id, unsupported_pattern: nil)
        row = @store.db.execute(
          "SELECT id FROM symbols WHERE framework_id = ? AND name = ? AND kind IN ('class', 'objc_class')",
          [fw_id, klass_name]
        ).first
        if row
          if unsupported_pattern
            hash = Digest::SHA256.hexdigest("#{fw_id}|#{klass_name}|class|swift_overlay")
            @store.insert_symbol(
              framework_id:        fw_id,
              name:                klass_name,
              kind:                "class",
              abi:                 "swift",
              content_hash:        hash,
              signature:           "class #{klass_name}",
              unsupported_pattern: unsupported_pattern
            )
          end
          return row.first
        end

        hash = Digest::SHA256.hexdigest("#{fw_id}|#{klass_name}|class|swift_overlay")
        @store.insert_symbol(
          framework_id:        fw_id,
          name:                klass_name,
          kind:                "class",
          abi:                 "swift",
          content_hash:        hash,
          signature:           "class #{klass_name}",
          unsupported_pattern: unsupported_pattern
        )
      end

      def upsert_decl(decl, klass:, klass_id:, fw_id:, unsupported_pattern: nil)
        selector = objc_selector_for(klass, decl)
        return unless selector

        swift_name = swift_imported_name_for(decl)
        kind_str   = kind_string_for(decl[:kind])
        hash       = Digest::SHA256.hexdigest("#{fw_id}|#{klass_id}|#{selector}|#{kind_str}|swift_overlay")

        params_json = parameters_json_for(decl[:params])

        @store.insert_symbol(
          framework_id:        fw_id,
          name:                selector,
          parent_id:           klass_id,
          kind:                kind_str,
          abi:                 "swift",
          content_hash:        hash,
          signature:            decl[:signature],
          return_type:         decl[:return_type],
          parameters_json:     params_json,
          swift_imported_name: swift_name,
          is_throws:           decl[:throws]   ? 1 : 0,
          is_async:            decl[:async]    ? 1 : 0,
          is_failable:         decl[:failable] ? 1 : 0,
          is_settable:         decl[:settable] ? 1 : 0,
          unsupported_pattern: unsupported_pattern
        )
      end

      def parameters_json_for(params)
        return nil if params.nil? || params.empty?

        JSON.generate(params.map { |p|
          { external_label: p[:external_label],
            internal_name:  p[:internal_name],
            type:           p[:type],
            nullable:       p[:nullable],
            default_value:  p[:default_value] }
        })
      end

      def kind_string_for(kind)
        case kind
        when :class_func, :static_func, :init  then "class_method"
        when :instance_func                    then "instance_method"
        when :class_var, :instance_var         then "instance_property"
        else                                        "unknown"
        end
      end
    end
  end
end
