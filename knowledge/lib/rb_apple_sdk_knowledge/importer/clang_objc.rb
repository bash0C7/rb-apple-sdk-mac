# frozen_string_literal: true
require "digest"
require "json"
require_relative "header_parser"

module AppleSDKKnowledge
  module Importer
    # File-level entry point for ingesting a single ObjC header into a Store.
    # The full Pipeline (`Importer::Pipeline`) processes whole SDK frameworks;
    # this helper exists for Phase 1 test fixtures that want to validate
    # individual `_Nullable` / `_Nonnull` capture behaviour without staging a
    # framework directory layout.
    module ClangObjc
      module_function

      # Parses `file` via HeaderParser, ensures `framework` row exists, and
      # writes each emitted symbol into `store`. parameters_json / fields_json
      # are JSON-serialised here so callers query SQLite directly.
      def import_file(store:, framework:, file:)
        fw_id = store.find_framework_id_by_name(framework)
        fw_id ||= store.insert_framework(name: framework, swift_module: framework)

        parser = HeaderParser.new
        parser.parse_file(file).each do |sym|
          # Salt content_hash with a stable parameters serialisation so
          # overloaded selectors (same parent_name / name / abi / signature
          # but divergent parameter types) do not collide on ON CONFLICT.
          # `objc_method_signature` only carries the return type and
          # selector, so without this salt e.g. `apply:(NSString *)` and
          # `apply:(NSNumber *)` hash identically and the second insert
          # silently clobbers the first.
          params_salt = sym[:parameters] ? JSON.generate(sym[:parameters]) : ""
          content_hash = Digest::SHA256.hexdigest(
            "#{framework}|#{sym[:parent_name]}|#{sym[:name]}|#{sym[:abi]}|#{sym[:signature]}|#{params_salt}"
          )
          store.insert_symbol(
            framework_id: fw_id,
            name: sym[:name],
            kind: sym[:kind],
            abi: sym[:abi],
            parent_id: nil,
            signature: sym[:signature],
            documentation: sym[:documentation],
            return_type: sym[:return_type],
            # Phase 1 T4: lift clang `cf_returns_retained` /
            # `NS_RETURNS_RETAINED` attributes from the AST to the
            # `return_ownership` column. Unannotated symbols stay nil
            # so the emitter naming heuristic remains the fallback.
            return_ownership: sym[:return_ownership],
            # Phase 1 T5: lift the typed-block signature that HeaderParser
            # already structured (return_type + params with nullability)
            # into the dedicated column. Pre-serialised by HeaderParser so
            # we just pass it through; nil stays nil → column is NULL when
            # the method takes no block parameter.
            callback_signature_json: sym[:callback_signature_json],
            # Phase 1 T6: `static inline` 関数は body が header に inline
            # 展開されるだけで dylib export を持たへん。 HeaderParser が
            # `inline_only` marker を立てた symbol を `unsupported_pattern`
            # 列に渡し、 Phase 2 dispatcher が call 時に rich diagnostic
            # で raise する判定材料とする。 通常 extern 関数は nil のまま。
            unsupported_pattern: sym[:unsupported_pattern],
            parameters_json: sym[:parameters] && JSON.generate(sym[:parameters]),
            fields_json: sym[:fields] && JSON.generate(sym[:fields]),
            content_hash: content_hash
          )
        end
      end
    end
  end
end
