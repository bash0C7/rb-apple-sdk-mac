# frozen_string_literal: true
require "digest"

module AppleSDKKnowledge
  module Importer
    class Consolidator
      def merge(swift_symbols, c_symbols)
        seen = {}
        (swift_symbols + c_symbols).each do |sym|
          key = "#{sym[:parent_name]}|#{sym[:name]}|#{normalize_signature(sym[:signature])}"
          existing = seen[key]
          if existing
            seen[key] = sym if sym[:abi] == "swift"
          else
            seen[key] = sym
          end
        end

        seen.values.map do |sym|
          sym.merge(content_hash: Digest::SHA256.hexdigest(
            "#{sym[:parent_name]}|#{sym[:name]}|#{normalize_signature(sym[:signature])}|#{sym[:abi]}"
          ))
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
