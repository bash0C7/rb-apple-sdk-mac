# frozen_string_literal: true

# spec §3 — Server / ServerFacade。 chiebukuro-mcp の Server class を rb-apple-sdk-mac
# 用に最小化。 v0.1 では tools = [probe_capabilities] のみ、 resources = [] (空)。
# 後続 phase で search / get_symbol_info / list_klass_methods / suggest_discover_call /
# dry_run_template / validate_call、 Resources を追加する。

module AppleSDKMac
  module MCP
    class Server
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
        tools     = build_tools
        resources, resource_handlers = build_resources_and_handlers

        mcp_server = ::MCP::Server.new(
          name:      "rb-apple-sdk-mac-mcp",
          version:   AppleSdkMac::VERSION,
          tools:     tools,
          resources: resources
        )

        mcp_server.resources_read_handler do |params|
          uri     = params[:uri] || params["uri"]
          handler = resource_handlers[uri]
          next [] unless handler
          [{ uri: uri, mimeType: "text/markdown", text: handler.call }]
        end

        ServerFacade.new(mcp_server, tools, resources)
      end

      def run
        require "mcp/server/transports/stdio_transport"
        facade    = build_mcp_server
        transport = ::MCP::Server::Transports::StdioTransport.new(facade)
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

      # MCP::Server のラッパー。 テストが期待する tool_classes / resource_list
      # interface を提供しつつ、 他のメソッド呼び出しは MCP::Server にデリゲート
      # する。 chiebukuro-mcp の ServerFacade と同じ流儀。
      class ServerFacade
        attr_reader :tool_classes, :resource_list

        def initialize(mcp_server, tools, resources)
          @mcp_server    = mcp_server
          @tool_classes  = tools
          @resource_list = resources
        end

        def respond_to_missing?(name, include_private = false)
          @mcp_server.respond_to?(name, include_private) || super
        end

        def method_missing(name, *args, **kwargs, &block)
          if @mcp_server.respond_to?(name)
            @mcp_server.send(name, *args, **kwargs, &block)
          else
            super
          end
        end
      end
    end
  end
end
