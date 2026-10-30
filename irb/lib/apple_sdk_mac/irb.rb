# frozen_string_literal: true

require "apple_sdk_mac"
require "apple_sdk_mac/irb/doc_resolver"
require "apple_sdk_mac/irb/doc_dialog"
require "apple_sdk_mac/irb/prefetcher"
require "apple_sdk_mac/irb/llm_resolver"

module AppleSDKMac
  module IRB
    Context = Struct.new(:framework, :klass, :receiver_kind, :prefix) do
      def self.parse(input)
        return nil unless input.is_a?(String)
        return nil unless input.start_with?("Apple::")
        rest = input[7..]

        if rest.empty? || rest.match?(/\A[A-Z][A-Za-z0-9_]*\z/)
          return new(nil, nil, :apple_root, rest)
        end

        if (m = rest.match(/\A([A-Z][A-Za-z0-9_]*)::([A-Za-z0-9_]*)\z/))
          return new(m[1], nil, :module, m[2])
        end

        if (m = rest.match(/\A([A-Z][A-Za-z0-9_]*)::([A-Z][A-Za-z0-9_]*)\.([A-Za-z0-9_]*)\z/))
          return new(m[1], m[2], :class, m[3])
        end

        nil
      end
    end

    SELECTOR_RE = /\A([A-Za-z_][A-Za-z0-9_]*).*/.freeze

    MODULE_KINDS = %w[
      class struct protocol enum_module function swift_func global_constant actor
    ].freeze

    KLASS_METHOD_KINDS = %w[
      objc_method_instance objc_method_class swift_init swift_property
      class_method instance_method instance_property enum_case
    ].freeze

    CAP = 100

    class CandidateProvider
      def initialize(knowledge_cache:)
        @cache = knowledge_cache
      end

      def call(context)
        return [] unless context
        case context.receiver_kind
        when :apple_root
          @cache.list_frameworks
            .select { |f| f =~ /\A[A-Z]/ && f.start_with?(context.prefix) }
            .first(CAP)
        when :module
          @cache.list_framework_symbols(
            framework: context.framework, kinds: MODULE_KINDS
          ).map { |r| r[:name] }
            .select { |n| n.start_with?(context.prefix) }
            .first(CAP)
        when :class
          @cache.list_klass_methods(
            framework: context.framework, klass: context.klass
          )
            .select { |r| KLASS_METHOD_KINDS.include?(r[:kind]) }
            .map { |r| ruby_method_name(r[:name]) }
            .uniq
            .select { |n| n.start_with?(context.prefix) }
            .first(CAP)
        else
          []
        end
      end

      private

      def ruby_method_name(symbol_name)
        m = symbol_name.match(SELECTOR_RE)
        m ? m[1] : symbol_name
      end
    end

    class AutoDiscoverer
      def initialize(knowledge_cache:, discover_proc: nil)
        @cache = knowledge_cache
        @discover = discover_proc || ->(**args) { ::Apple.discover(**args) }
      end

      def run(context, chosen_name)
        return if context.nil?
        return if context.receiver_kind != :class

        record = lookup_method_record(context, chosen_name)
        return if record.nil?

        kwargs = build_discover_kwargs(context, record, chosen_name)
        return unless kwargs
        @discover.call(**kwargs)
      end

      private

      def lookup_method_record(context, chosen_name)
        rows = @cache.list_klass_methods(
          framework: context.framework, klass: context.klass
        )
        rows.find { |r| ruby_name(r[:name]) == chosen_name }
      end

      def ruby_name(symbol_name)
        m = symbol_name.match(/\A([A-Za-z_][A-Za-z0-9_]*).*/)
        m ? m[1] : symbol_name
      end

      def build_discover_kwargs(context, record, chosen_name)
        base = { framework: context.framework.to_sym, klass: context.klass.to_sym }
        case record[:kind]
        when "objc_method_class", "class_method"
          base.merge(class_method: record[:name])
        when "objc_method_instance", "instance_method"
          base.merge(selector: record[:name])
        when "swift_init"
          base.merge(swift_initializer: record[:name])
        when "swift_property"
          base.merge(swift_property: chosen_name.to_sym, instance: true)
        else
          nil
        end
      end
    end

    class Completor
      def initialize(provider:, base: nil)
        @provider = provider
        @base = base
      end

      def completion_candidates(preposing, target, postposing, bind:)
        input = "#{preposing}#{target}"
        context = Context.parse(input)
        if context
          raw = @provider.call(context) || []
          return prefix_candidates(context, raw)
        end
        @base ? @base.completion_candidates(preposing, target, postposing, bind: bind) : []
      end

      private def prefix_candidates(context, raw)
        case context.receiver_kind
        when :apple_root
          raw.map { |c| "Apple::#{c}" }
        when :module
          raw.map { |c| "Apple::#{context.framework}::#{c}" }
        when :class
          raw.map { |c| "Apple::#{context.framework}::#{context.klass}.#{c}" }
        else
          raw
        end
      end

      def doc_namespace(preposing, target, postposing, bind:)
        @base&.doc_namespace(preposing, target, postposing, bind: bind)
      end

      def inspect
        base_info = @base ? @base.inspect : "no-base"
        "AppleCompletor(base=#{base_info})"
      end
    end

    @installed = false

    class << self
      def install!(knowledge_cache: nil, discover_proc: nil)
        return if @installed
        require "irb"
        knowledge_cache ||= AppleSDKMac.knowledge_cache
        provider = CandidateProvider.new(knowledge_cache: knowledge_cache)
        discoverer = AutoDiscoverer.new(
          knowledge_cache: knowledge_cache,
          discover_proc: discover_proc
        )

        ::IRB.conf[:COMPLETOR] = :type

        @apple_provider = provider
        resolver = DocResolver.new(knowledge_cache: knowledge_cache)
        @apple_prefetcher = Prefetcher.new(discoverer: discoverer)
        @apple_llm_resolver = build_llm_resolver(knowledge_cache: knowledge_cache)
        @apple_doc_dialog = DocDialog.new(
          resolver: resolver,
          prefetcher: @apple_prefetcher,
          llm_resolver: @apple_llm_resolver
        )

        unless ::IRB::Context.include?(ContextOverride)
          ::IRB::Context.prepend(ContextOverride)
        end

        unless ::IRB::RelineInputMethod.include?(RelineInputMethodOverride)
          ::IRB::RelineInputMethod.prepend(RelineInputMethodOverride)
        end

        @installed = true
      end

      def uninstall!
        @installed = false
        @apple_provider = nil
        @apple_doc_dialog = nil
        @apple_prefetcher = nil
        @apple_llm_resolver = nil
      end

      def installed?
        @installed
      end

      attr_reader :apple_provider, :apple_doc_dialog,
                  :apple_prefetcher, :apple_llm_resolver

      private

      def build_llm_resolver(knowledge_cache:)
        return nil if ENV["APPLE_IRB_NO_LLM"] == "1"
        begin
          require "foundation_model_mac"
        rescue LoadError => e
          warn "[apple-sdk-mac irb] foundation_model_mac unavailable: #{e.message}" if ENV["APPLE_IRB_DEBUG"]
          return nil
        end
        llm_proc = ->(prompt) {
          response = ::AppleFoundationModel.generate(prompt: prompt)
          response.is_a?(String) ? response : response.to_s
        }
        LLMResolver.new(llm_proc: llm_proc, knowledge_cache: knowledge_cache)
      end
    end

    module ContextOverride
      def build_completor
        if AppleSDKMac::IRB.installed? && AppleSDKMac::IRB.apple_provider
          base = super
          if base.is_a?(::IRB::RegexpCompletor)
            Completor.new(provider: AppleSDKMac::IRB.apple_provider, base: nil)
          else
            Completor.new(provider: AppleSDKMac::IRB.apple_provider, base: base)
          end
        else
          super
        end
      end
    end

    module RelineInputMethodOverride
      def initialize(*args, **kwargs)
        super
        if AppleSDKMac::IRB.installed?
          require "reline"
          if AppleSDKMac::IRB.apple_doc_dialog
            irb_proc   = show_doc_dialog_proc
            apple_proc = AppleSDKMac::IRB.apple_doc_dialog.to_proc
            chained = ->() {
              saved = context.dup
              apple_result = instance_exec(&apple_proc)
              return apple_result if apple_result
              context.replace(saved)
              begin
                instance_exec(&irb_proc)
              rescue StandardError => e
                warn "[apple-sdk-mac show_doc fallback] #{e.class}: #{e.message}" if ENV["APPLE_IRB_DEBUG"]
                nil
              end
            }
            Reline.add_dialog_proc(:show_doc, chained, Reline::DEFAULT_DIALOG_CONTEXT)
          end
        end
      end
    end
  end
end
