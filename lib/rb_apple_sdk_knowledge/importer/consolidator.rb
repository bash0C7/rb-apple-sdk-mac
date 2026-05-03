# frozen_string_literal: true
require "digest"

module AppleSDKKnowledge
  module Importer
    class Consolidator
      def merge(swift_symbols, c_symbols, docc_symbols)
        docc_by_name = docc_symbols.each_with_object({}) do |sym, h|
          h[sym[:name]] = sym if sym[:name]
        end

        all_symbols = swift_symbols + c_symbols
        seen = {}
        all_symbols.each do |sym|
          key = "#{sym[:parent_name]}|#{sym[:name]}|#{normalize_signature(sym[:signature])}"
          existing = seen[key]
          if existing
            seen[key] = sym if sym[:abi] == "swift"
          else
            seen[key] = sym
          end
        end

        seen.values.map do |sym|
          docc = docc_by_name[sym[:name]]
          enriched = sym.merge(documentation: sym[:documentation] || docc&.fetch(:documentation, nil))
          enriched[:content_hash] = Digest::SHA256.hexdigest(
            "#{sym[:parent_name]}|#{sym[:name]}|#{normalize_signature(sym[:signature])}|#{sym[:abi]}"
          )
          enriched
        end
      end

      private

      def normalize_signature(sig)
        return "" if sig.nil?
        sig.gsub(/\s+/, " ").gsub(/\b_\s+\w+:/, "").strip
      end
    end
  end
end
