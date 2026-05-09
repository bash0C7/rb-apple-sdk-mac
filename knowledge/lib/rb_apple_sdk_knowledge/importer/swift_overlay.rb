# frozen_string_literal: true
require "strscan"
require "digest"

module AppleSDKKnowledge
  module Importer
    # Swift overlay ingester: parses .swiftinterface files that contain
    # Swift native type declarations (AVFoundation / Vision / SwiftUI etc.)
    # and writes both the ObjC selector and its Swift imported name into
    # the Knowledge Base SQLite.
    #
    # Parse strategy: regex-based line scanning. Generic / async / throws /
    # where clauses that can't be reliably parsed are skipped; the LLM safety
    # net handles those (coverage > speed tenet).
    class SwiftOverlay
      EXTENSION_HEADER_RE = /\bextension\s+(\w+)\s*\{/.freeze

      # Matches: (open|public) [class|static] func name(params) [-> RetType]
      # Captures: [1] class/static?, [2] func name, [3] raw params, [4] return type
      DECL_FUNC_RE = /(?:open|public)\s+(?:(class|static)\s+)?func\s+(\w+)\s*\(([^)]*)\)(?:\s*->\s*([^\n{]+))?/.freeze

      # Matches: (open|public) [convenience|required] init(params)
      # Captures: [1] qualifier?, [2] raw params
      DECL_INIT_RE = /(?:open|public)\s+(?:(convenience|required)\s+)?init\s*\(([^)]*)\)/.freeze

      # Matches: (open|public) [class|static] var name: Type
      # Captures: [1] class/static?, [2] var name, [3] type
      DECL_VAR_RE = /(?:open|public)\s+(?:(class|static)\s+)?var\s+(\w+)\s*:\s*([^\n{]+)/.freeze

      def initialize(store)
        @store = store
      end

      # -- extension scanner --------------------------------------------------

      # Returns [{klass: String, body: String}] for each `extension Foo { ... }`
      # block found in +source+. Uses StringScanner with brace-counting so
      # nested braces inside method signatures are handled correctly.
      def extract_extension_blocks(source)
        scanner = StringScanner.new(source)
        blocks  = []

        until scanner.eos?
          if (m = scanner.scan_until(EXTENSION_HEADER_RE))
            klass      = scanner.captures.first || m[/extension\s+(\w+)/, 1]
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

      # -- declaration parser -------------------------------------------------

      # Parses a single line from an extension body.
      # Returns a Hash or nil if unparseable.
      #
      # Returned keys:
      #   kind:        :class_func | :instance_func | :init | :class_var | :instance_var
      #   name:        String
      #   params:      Array<{label:, internal:, type:}>
      #   return_type: String or nil
      #   signature:   String (raw trimmed line)
      def parse_decl_line(line)
        stripped = line.strip

        if (m = stripped.match(DECL_FUNC_RE))
          is_class = !m[1].nil?
          name     = m[2]
          params   = parse_params(m[3])
          ret      = m[4]&.strip
          kind     = is_class ? :class_func : :instance_func
          { kind: kind, name: name, params: params, return_type: ret, signature: stripped }

        elsif (m = stripped.match(DECL_INIT_RE))
          params = parse_params(m[2])
          { kind: :init, name: "init", params: params, return_type: nil, signature: stripped }

        elsif (m = stripped.match(DECL_VAR_RE))
          is_class = !m[1].nil?
          kind     = is_class ? :class_var : :instance_var
          { kind: kind, name: m[2], params: [], return_type: m[3].strip, signature: stripped }

        else
          nil
        end
      end

      # Parses a raw Swift parameter list string into structured form.
      # e.g. "for mediaType: AVMediaType" =>
      #   [{label: "for", internal: "mediaType", type: "AVMediaType"}]
      def parse_params(raw)
        return [] if raw.nil? || raw.strip.empty?

        raw.split(",").filter_map do |part|
          part = part.strip
          next nil if part.empty?

          if (m = part.match(/\A(\w+|\?|_)\s+(\w+)\s*:\s*(.+)\z/))
            { label: m[1], internal: m[2], type: m[3].strip }
          elsif (m = part.match(/\A(\w+)\s*:\s*(.+)\z/))
            { label: m[1], internal: m[1], type: m[2].strip }
          else
            nil
          end
        end
      end

      # -- selector reconstruction --------------------------------------------

      # Reconstructs the ObjC selector for a parsed declaration.
      # Returns String (e.g. "devicesWithMediaType:") or nil.
      #
      # Apple's ObjC naming convention for Swift functions:
      # - When the first param has label == internal (or label is "_"):
      #     func foo(bar baz:) → "fooBar:" or "foo:" (underscore label)
      # - When the first param has label != internal (e.g. func foo(for mediaType:)):
      #     the ObjC name uses "With<InternalName>" suffix → "fooWithMediaType:"
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

      # Builds the Swift imported name for a declaration.
      # e.g. {name: "devices", params: [{label: "for", ...}]} => "devices(for:)"
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

      # -- persistence --------------------------------------------------------

      # Public entry point. Reads the .swiftinterface file at +path+, parses
      # Swift extension blocks, reconstructs ObjC selectors, and writes rows
      # into the Knowledge Base Store.
      def import!(framework:, path:)
        source = File.read(path)
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
      end

      private

      def capitalize(str)
        return str if str.empty?
        str[0].upcase + str[1..]
      end

      # Computes the ObjC suffix for the first param of a func declaration.
      # When label == internal (or label is "_"), uses the label directly.
      # When label != internal (e.g. "for" vs "mediaType"), uses "With<Internal>".
      def first_param_suffix(param)
        label    = param[:label]
        internal = param[:internal]
        if label == "_"
          ""
        elsif label == internal
          capitalize(label)
        else
          # label is a preposition (for/in/at/with/etc.) — Apple convention:
          # func foo(for bar:) → "fooWithBar:"
          "With#{capitalize(internal)}"
        end
      end

      # Variant for init: always "With<Internal>" based on the internal name.
      def first_param_with_suffix(param)
        label    = param[:label]
        internal = param[:internal]
        if label == "_"
          capitalize(internal)
        else
          capitalize(internal)
        end
      end

      # Computes the ObjC selector part for subsequent (non-first) params.
      def rest_param_part(param)
        param[:label] == "_" ? ":" : "#{param[:label]}:"
      end

      def upsert_framework(name)
        existing = @store.find_framework_id_by_name(name)
        return existing if existing

        @store.insert_framework(name: name, swift_module: name, category: "swift_overlay")
      end

      def upsert_klass(klass_name, fw_id)
        row = @store.db.execute(
          "SELECT id FROM symbols WHERE framework_id = ? AND name = ? AND kind IN ('class', 'objc_class')",
          [fw_id, klass_name]
        ).first
        return row.first if row

        hash = Digest::SHA256.hexdigest("#{fw_id}|#{klass_name}|class|swift_overlay")
        @store.insert_symbol(
          framework_id: fw_id,
          name:         klass_name,
          kind:         "class",
          abi:          "swift",
          content_hash: hash,
          signature:    "class #{klass_name}"
        )
      end

      def upsert_decl(decl, klass:, klass_id:, fw_id:)
        selector = objc_selector_for(klass, decl)
        return unless selector

        swift_name = swift_imported_name_for(decl)
        kind_str   = kind_string_for(decl[:kind])
        hash       = Digest::SHA256.hexdigest("#{fw_id}|#{klass_id}|#{selector}|#{kind_str}|swift_overlay")

        sym_id = @store.insert_symbol(
          framework_id: fw_id,
          name:         selector,
          parent_id:    klass_id,
          kind:         kind_str,
          abi:          "swift",
          content_hash: hash,
          signature:    decl[:signature]
        )

        return unless sym_id && swift_name

        @store.db.execute(
          "UPDATE symbols SET swift_imported_name = ? WHERE id = ?",
          [swift_name, sym_id]
        )
      end

      def kind_string_for(kind)
        case kind
        when :class_func    then "objc_method_class"
        when :instance_func then "instance_method"
        when :init          then "objc_method_class"
        when :class_var     then "class_property"
        when :instance_var  then "instance_property"
        else                     "unknown"
        end
      end
    end
  end
end
