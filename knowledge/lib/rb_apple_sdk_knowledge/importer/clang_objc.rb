# frozen_string_literal: true
require "digest"
require "json"
require_relative "header_parser"

module AppleSDKKnowledge
  module Importer
    module ClangObjc
      module_function

      def import_file(store:, framework:, file:)
        fw_id = store.find_framework_id_by_name(framework)
        fw_id ||= store.insert_framework(name: framework, swift_module: framework)

        parser = HeaderParser.new
        parser.parse_file(file).each do |sym|
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
            return_ownership: sym[:return_ownership],
            callback_signature_json: sym[:callback_signature_json],
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
