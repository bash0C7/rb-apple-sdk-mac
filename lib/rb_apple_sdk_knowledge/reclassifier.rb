# frozen_string_literal: true
require "json"
require_relative "importer/kind"

module AppleSDKKnowledge
  class Reclassifier
    K = AppleSDKKnowledge::Importer::Kind

    def self.recompute_parameters(json)
      return nil if json.nil? || json.empty?
      params = JSON.parse(json, symbolize_names: true)
      pointer_params = params.select { |p| (p[:type] || "").include?("*") }
      last_pointer = pointer_params.last

      params.each_with_index.map do |p, i|
        qual_type = p[:type] || ""
        name = p[:name] || "_arg#{i}"
        p.merge(
          kind: K.classify_kind(qual_type),
          is_out_param: K.out_param?(qual_type, name, p.equal?(last_pointer)),
          nullability: K.nullability_of(qual_type)
        )
      end.then { |xs| JSON.generate(xs) }
    end
  end
end
