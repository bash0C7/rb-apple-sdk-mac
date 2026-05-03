# frozen_string_literal: true
require "json"
require "open3"

module AppleSDKKnowledge
  module Importer
    class DoccParser
      def from_render_json(node)
        title = node.dig("metadata", "title")
        abstract = (node["abstract"] || [])
          .select { |frag| frag["type"] == "text" }
          .map { |frag| frag["text"] }
          .join

        {
          name: title,
          documentation: abstract,
          kind_hint: node.dig("metadata", "symbolKind")
        }
      end

      def parse_doccarchive(path)
        results = []
        Dir.glob(File.join(path, "data", "documentation", "**", "*.json")).each do |json_path|
          json = JSON.parse(File.read(json_path))
          sym = from_render_json(json)
          results << sym if sym[:name]
        rescue JSON::ParserError
          # skip malformed
        end
        results
      end
    end
  end
end
