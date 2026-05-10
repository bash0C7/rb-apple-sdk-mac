# frozen_string_literal: true
require "json"
require "time"

# Server。 tools = [search, get_symbol_info, list_klass_methods,
# suggest_discover_call, dry_run_template, validate_call, probe_capabilities]、
# resources = [static_doc, framework_list, stats]。

module AppleSDKMac
  module MCP
    class Server
      attr_reader :tool_classes, :resource_list
      # 各 MCP tool 呼び出しを wrap して構造化 JSON ログを stderr に 1 行吐く。
      # tool 内 block 末尾の Response を return する。
      class << self
        def wrap_with_log(tool_name:, &block)
          t0     = Time.now
          result = block.call
          elapsed_ms = ((Time.now - t0) * 1000).to_i
          entry = {
            ts:          t0.iso8601,
            kind:        "tool_call",
            tool:        tool_name,
            result_rows: extract_row_count(result),
            elapsed_ms:  elapsed_ms
          }
          warn JSON.generate(entry)
          result
        end

        # MCP::Tool::Response から result_rows を best-effort 推定。 Array JSON
        # は length、 それ以外 (object / scalar / parse 失敗) は 0。 ログの目的は
        # 偏り観測なので厳密性より頑健性を優先。
        def extract_row_count(response)
          return 0 unless response.respond_to?(:content)
          first = response.content.first
          text  = first[:text] || first["text"]
          return 0 unless text.is_a?(String)
          parsed = JSON.parse(text)
          parsed.is_a?(Array) ? parsed.length : 0
        rescue StandardError
          0
        end
      end

      def initialize(kb: nil)
        @kb = kb
      end

      # KB は遅延 open。 テストでは Struct ベースの fake を inject、 production では
      # AppleSDKMac::KnowledgeCache.open (親 gem が AppleSDKKnowledge.open を wrap
      # した #search / #lookup_symbol / #list_klass_methods を持つ class) を使う。
      # KB が無い (rake apple:knowledge:rebuild 未実行) 場合はここで raise する。
      def kb
        @kb ||= AppleSDKMac::KnowledgeCache.open
      end

      def build_mcp_server
        @tool_classes  = build_tools
        @resource_list, resource_handlers = build_resources_and_handlers

        mcp_server = ::MCP::Server.new(
          name:      "rb-apple-sdk-mac-mcp",
          version:   AppleSdkMac::VERSION,
          tools:     @tool_classes,
          resources: @resource_list
        )

        mcp_server.resources_read_handler do |params|
          uri     = params[:uri] || params["uri"]
          handler = resource_handlers[uri]
          next [] unless handler
          [{ uri: uri, mimeType: "text/markdown", text: handler.call }]
        end

        mcp_server
      end

      def run
        require "mcp/server/transports/stdio_transport"
        mcp_server = build_mcp_server
        transport  = ::MCP::Server::Transports::StdioTransport.new(mcp_server)
        transport.open
      end

      private

      def build_tools
        [
          Tools::ProbeCapabilities.tool_class,
          Tools::Search.tool_class(kb: kb),
          Tools::GetSymbolInfo.tool_class(kb: kb),
          Tools::ListKlassMethods.tool_class(kb: kb),
          Tools::SuggestDiscoverCall.tool_class(kb: kb),
          Tools::DryRunTemplate.tool_class(kb: kb),
          Tools::ValidateCall.tool_class(kb: kb)
        ]
      end

      STATIC_DOC_DEFS = [
        { uri: "apple-sdk-mac://discover-shapes",  filename: "discover-shapes.md",
          name: "discover-shapes",  description: "Apple.discover の 7 個の keyword shape カタログ" },
        { uri: "apple-sdk-mac://dispatch-flow",    filename: "dispatch-flow.md",
          name: "dispatch-flow",    description: "Apple.discover → glue compile → method dispatch の全フロー" },
        { uri: "apple-sdk-mac://kind-catalog",     filename: "kind-catalog.md",
          name: "kind-catalog",     description: "KB kind と生成される Ruby メソッド形の対応表" },
        { uri: "apple-sdk-mac://override-recipes", filename: "override-recipes.md",
          name: "override-recipes", description: "params: / return_kind: で KB 分類を override する手順" },
        { uri: "apple-sdk-mac://proxy-wrap-rules", filename: "proxy-wrap-rules.md",
          name: "proxy-wrap-rules", description: "opaque_ref / cftype_ref 戻り値の auto-wrap ルール" },
        { uri: "apple-sdk-mac://callback-patterns", filename: "callback-patterns.md",
          name: "callback-patterns", description: "callback / async / threading / event_loop の使い分け" }
      ].freeze

      def build_resources_and_handlers
        resources = []
        handlers  = {}

        STATIC_DOC_DEFS.each do |d|
          resources << ::MCP::Resource.new(
            uri:         d[:uri],
            name:        d[:name],
            description: d[:description],
            mime_type:   "text/markdown"
          )
          handlers[d[:uri]] = Resources::StaticDocResource.new(filename: d[:filename])
        end

        fw_uri = "apple-sdk-mac://framework-list"
        resources << ::MCP::Resource.new(
          uri:         fw_uri,
          name:        "framework-list",
          description: "KB に存在する Apple framework 一覧 (動的)",
          mime_type:   "text/markdown"
        )
        handlers[fw_uri] = Resources::FrameworkListResource.new(kb: kb)

        stats_uri = "apple-sdk-mac://stats"
        resources << ::MCP::Resource.new(
          uri:         stats_uri,
          name:        "stats",
          description: "KB 統計 (frameworks 数 / symbols 数 / kind 内訳)",
          mime_type:   "text/markdown"
        )
        handlers[stats_uri] = Resources::StatsResource.new(kb: kb)

        [resources, handlers]
      end
    end
  end
end
