# frozen_string_literal: true
require "strscan"
require "digest"
require "json"

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
      # Matches: extension <DottedName>(.\w+)*(\s*:\s*<Conformances>)?(\s+where\s+...)?\s*\{
      # Captures: [1] dotted name (e.g. "Foundation.URL", "Foundation.URL.ParseStrategy")
      # Real Apple .swiftinterface always uses module-qualified names; klass key
      # is taken as the LAST dotted segment by extract_extension_blocks.
      EXTENSION_HEADER_RE = /\bextension\s+([A-Za-z_][\w.]*)[^{]*\{/.freeze

      # Matches: (open|public) [class|static] func name(params) [throws/async/rethrows]* [-> RetType]
      # Captures: [1] class/static?, [2] func name, [3] raw params,
      #           [4] effect modifiers (throws/async/rethrows, space-separated, or nil),
      #           [5] return type
      # `(?:<[^>]+>)?` after the function name accepts generic type parameters
      # like `func publisher<Value>(...)` that appear in real Apple
      # .swiftinterface (Foundation/AppKit/Vision/SwiftUI overlay).
      # `func parse(_:) throws -> URL` / `func fetch() async throws -> Data` 形を
      # capture できるよう、 effect modifiers (`async`/`throws`/`rethrows`) を
      # `)` と `->` の間で吸収する。 modifier 不在時は capture group 4 が nil。
      DECL_FUNC_RE = /(?:open|public)\s+(?:(class|static)\s+)?func\s+(\w+)(?:<[^>]+>)?\s*\(([^)]*)\)((?:\s+(?:async|throws|rethrows))*)?(?:\s*->\s*([^\n{]+))?/.freeze

      # Matches: (open|public) [convenience|required] init[?](params) [throws/rethrows]*
      # Captures: [1] qualifier?, [2] failable mark (?) or empty, [3] raw params,
      #           [4] effect modifiers (throws/rethrows, optional)
      # `init\??` accepts both `init(...)` and Swift failable initializers
      # `init?(...)` which appear throughout Foundation overlay (URL, etc.).
      # `init(forReading:) throws` を capture できるよう effect modifiers を
      # 末尾で吸収する。
      DECL_INIT_RE = /(?:open|public)\s+(?:(convenience|required)\s+)?init(\??)\s*\(([^)]*)\)((?:\s+(?:throws|rethrows))*)?/.freeze

      # Matches: (open|public) [class|static] var name: Type
      # Captures: [1] class/static?, [2] var name, [3] type
      DECL_VAR_RE = /(?:open|public)\s+(?:(class|static)\s+)?var\s+(\w+)\s*:\s*([^\n{]+)/.freeze

      # Matches: (open|public) [indirect] enum <Name>[: <Conformances>]? {
      # Captures: [1] enum name. Optional raw-value / conformance clause
      # (e.g. `: String`, `: RawRepresentable, Codable`) is absorbed by the
      # non-greedy `[^\n{]*` between the name and the opening brace, so the
      # enum is recognised regardless of conformance shape. Phase 1 T12:
      # the parser only captures top-level enum declarations — nested enums
      # inside extension blocks fall through to the existing extension path
      # and are handled (or not) by the line-decl scanner.
      DECL_ENUM_RE = /(?:open|public)\s+(?:indirect\s+)?enum\s+(\w+)(?:[^\n{]*)\{/.freeze

      # Matches a `case` line inside an enum body. Captures [1] one or more
      # case names separated by commas (e.g. `case a, b, c`). Trailing
      # associated-value parens `case load(Data)` or raw-value assignments
      # `case foo = "f"` are tolerated — the regex only locks onto the
      # identifier head(s) and lets parse_enum_block_cases split commas.
      CASE_RE = /^\s*case\s+([a-zA-Z_]\w*(?:\s*,\s*[a-zA-Z_]\w*)*)/.freeze

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
            dotted     = scanner.captures.first || m[/extension\s+([A-Za-z_][\w.]*)/, 1]
            # Real Apple .swiftinterface uses module-qualified or nested-type
            # names: "Foundation.URL", "Foundation.URL.ParseStrategy". The KB
            # key is the type identifier alone — last dotted segment.
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

      # -- enum scanner -------------------------------------------------------

      # Returns [{name: String, cases: Array<String>}] for each top-level
      # `public enum Foo { ... }` block found in +source+. Brace-counted
      # body extraction mirrors extract_extension_blocks so nested type
      # braces don't bleed across enum boundaries.
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

      # Extracts flat case-name array from an enum body. Multi-name
      # `case a, b, c` is expanded into separate entries. Associated-value
      # / raw-value tails (`case load(Data)` / `case foo = "f"`) are
      # ignored — only the identifier head is retained.
      def parse_case_names(body)
        names = []
        body.scan(CASE_RE) do |m|
          m[0].split(",").map(&:strip).each { |c| names << c unless c.empty? }
        end
        names
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
      #   throws:      Boolean (func / init で `throws` 末尾を持つか)
      #   async:       Boolean (func の `async` 末尾、 init には立たない)
      #   failable:    Boolean (init? の `?` を持つか、 func/var には常に false)
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
          { kind: kind, name: m[2], params: [], return_type: m[3].strip,
            throws: false, async: false, failable: false,
            signature: stripped }

        else
          nil
        end
      end

      # Parses a raw Swift parameter list string into structured form.
      # e.g. "for mediaType: AVMediaType" =>
      #   [{label: "for", internal: "mediaType", type: "AVMediaType",
      #     external_label: "for", internal_name: "mediaType"}]
      #
      # Phase 1 T9: each element now also carries explicit
      # +external_label+ / +internal_name+ keys mirroring Swift's two
      # parameter naming positions, so a Phase 2 emitter can pick the
      # right name without re-parsing the signature string. Conventions:
      # - `_ raw: String`     → external_label = nil, internal_name = "raw"
      # - `url: URL`          → external_label = internal_name = "url"
      # - `forReading url: U` → external_label = "forReading", internal_name = "url"
      # The legacy `:label` / `:internal` shorthand is preserved for the
      # selector reconstruction path (objc_selector_for / swift_imported_name_for).
      #
      # Phase 1 T10: per-parameter literal default values are extracted via
      # extract_default_value and exposed as the +default_value+ key. The
      # regex now captures an optional `= <expr>` tail with a non-greedy
      # type fragment so `Int = 42` is split into type=Int / default=42.
      # Non-literal expressions (closures / function calls / arithmetic)
      # collapse to default_value = nil at the extractor; the raw `=`
      # fragment is consumed regardless so the type column stays clean.
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

      # Recognised Swift literal default expressions:
      #   numeric          → 42 / -3.14
      #   string           → "default"
      #   dot-enum case    → .utf8 / .red
      #   bool / nil       → true / false / nil
      # 複雑 expression (closure / function call / arithmetic) は nil を返す。
      # Phase 2 emitter は default_value 非 nil の引数なら glue で省略可能、
      # nil なら user に explicit に渡してもらう policy で利用する。
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

      # Determines whether the *outer* form of a Swift type expression is
      # Optional (`T?` / `T??`) or Implicitly-Unwrapped Optional (`T!`).
      # Crude string `end_with?("?")` 判定では `Array<URL?>` のような
      # 内側 ? が誤検出されるため、 paren / bracket / angle の depth balance
      # を確認し、 末尾文字が ? or ! でかつ depth が 0 に閉じてる時のみ
      # outer optional とみなす。 Phase 2 emitter は nullable=true で
      # Ruby 側 nil 受容 / NULL bridging path を、 false で non-null 前提
      # glue を選ぶ。
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

        # Phase 1 T12: top-level `public enum X { case ... }` declarations
        # are not exposed via the extension scanner. Ingest them as their
        # own symbol rows with kind="enum" and serialise the case-name
        # list into enum_cases_json. Phase 2 namespace_builder reads this
        # column to install `Apple::<Framework>::<Enum>::<Case>` constants.
        extract_enum_blocks(source).each do |enum_block|
          upsert_enum(enum_block, fw_id: fw_id)
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

      # Variant for init: always Capitalize<Internal>, regardless of whether
      # the Swift label is "_" or a preposition. Apple's ObjC bridging
      # convention for initializers is uniformly "initWith<Internal>:" — the
      # external label never participates in the selector head.
      def first_param_with_suffix(param)
        capitalize(param[:internal])
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

      # Inserts a top-level Swift enum symbol with its case list serialised
      # to enum_cases_json. Idempotent via the (framework_id, name, kind)
      # selector check — re-imports under the same content_hash collapse
      # into the same row through Store#insert_symbol's ON CONFLICT path.
      # Empty case lists serialise to nil so the column stays NULL for
      # zero-case (degenerate) enum declarations.
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

        # Single atomic INSERT ... ON CONFLICT — swift_imported_name rides
        # along so a re-import under the same content_hash updates this
        # column in the same statement.
        # return_type は downstream emitter (rb-apple-sdk-mac) が wrap_class /
        # marshalling 判定に使うため Swift overlay 由来 row でも DB に乗せる。
        # Phase 1 T8: lift parse-time effect modifiers (throws / async /
        # failable) into schema columns so Phase 2 emitter can pick
        # AndReturnError marshalling and Optional unwrap paths from a
        # SELECT without re-parsing the signature string.
        # Phase 1 T9: serialise per-parameter external_label / internal_name /
        # type into parameters_json so Phase 2 emitter can pick Swift's
        # call-site label and the in-body identifier directly from a
        # SELECT, no signature string re-parse.
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
          is_failable:         decl[:failable] ? 1 : 0
        )
      end

      # Serialises the parameter list into the canonical user-facing JSON
      # payload. Internal-only keys (`:label` / `:internal`) used for
      # selector reconstruction are intentionally dropped — the Knowledge
      # Base surface keeps only `external_label` / `internal_name` /
      # `type` / `default_value` per element. Returns nil for empty
      # parameter lists so the column stays NULL for zero-arg declarations.
      # Phase 1 T10: `default_value` carries a Swift literal default expression
      # (numeric / string / dot-prefixed enum case / bool / nil) when present,
      # nil otherwise. Phase 2 emitter uses non-nil entries to omit args in
      # generated glue and falls back to explicit user-passing when nil.
      # Phase 1 T11: `nullable` carries the outer-Optional / IUO judgement
      # (`URL?` / `URL!` → true、 `Array<URL?>` → false) per parameter so
      # Phase 2 emitter picks NULL bridging vs non-null glue without
      # re-parsing the type string at codegen time.
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

      # Maps parser-internal :symbol kinds to canonical Knowledge Base kind
      # strings. Canonical values (verified via SELECT DISTINCT kind FROM
      # symbols on a populated sdk_knowledge.sqlite):
      #   actor, class, class_method, enum_case, enum_module, function,
      #   global_constant, instance_method, instance_property, protocol, struct
      #
      # Notes:
      # - There is no "class_property" in the canonical set; static / class
      #   var declarations are folded into "instance_property", matching
      #   swift_interface_parser.rb's existing convention (which collapses
      #   public var / public let — instance or static — to instance_property).
      # - :init maps to "class_method" because Swift initializers ingest as
      #   class-level entry points (matching swift_interface_parser.rb).
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
