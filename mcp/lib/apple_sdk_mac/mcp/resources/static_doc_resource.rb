# frozen_string_literal: true

module AppleSDKMac
  module MCP
    module Resources
      class StaticDocResource
        DOCS_DIR = File.expand_path("../../../../docs/resources", __dir__)

        def initialize(filename:)
          @path = File.join(DOCS_DIR, filename)
        end

        def call
          File.read(@path)
        rescue Errno::ENOENT
          "(documentation file not found: #{@path})"
        end
      end
    end
  end
end
