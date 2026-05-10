# frozen_string_literal: true

# IRB autocomplete + doc preview + auto-discover prefetch for rb-apple-sdk-mac.
#
# Activated by:
#   require "apple_sdk_mac"      # main gem
#   require "apple_sdk_mac/irb"  # this sub-gem
#   AppleSDKMac::IRB.install!
#
# Logical sub-gem inside the rb-apple-sdk-mac repo, path-loaded via Gemfile.
# Never auto-required by lib/apple_sdk_mac.rb so non-IRB users do not pull
# in irb / reline / repl_type_completor / foundation_model_mac.
#
# NOTE: stdlib IRB is referenced as `::IRB::...` because bare `IRB` inside
# `module AppleSDKMac::IRB` resolves to self (this module), not the stdlib.

require "apple_sdk_mac"
require "apple_sdk_mac/irb/doc_resolver"
require "apple_sdk_mac/irb/doc_dialog"
require "apple_sdk_mac/irb/prefetcher"
require "apple_sdk_mac/irb/llm_resolver"

module AppleSDKMac
  module IRB
    Context = Struct.new(:framework, :klass, :receiver_kind, :prefix) do
      # Parse Reline input line into framework/klass/prefix.
      # Returns nil for non-Apple paths.
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

    # 補完で確定した method 名を Apple.discover の正しい keyword shape に
    # マッピングして同期実行する。 parameters / return_kind は明示せず、
    # compiler pipeline に shape 推論を任せる。
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

    # IRB::Context#build_completor が返す completor を差し替える形で
    # IRB の completion 経路に乗る。 Reline.completion_proc 直 wrap は
    # IRB::RelineInputMethod#initialize で必ず上書きされるので機能しない。
    #
    # Apple:: 始まりは Apple Provider 、 それ以外は base (TypeCompletor) に
    # delegate して **標準補完と両立**。 標準の RegexpCompletor は Ruby 4 +
    # RUBY_BOX=1 で `bind.eval_class_constants` が Apple Box フレームと衝突
    # して SEGV するため使えないが、 TypeCompletor (repl_type_completor 経由
    # の AST/RBS ベース推論) は constant enumerate しないので安全。
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

      # Reline matches `target` against candidate prefix. IRB's
      # BASIC_WORD_BREAK_CHARACTERS excludes `:` and `.`, so target is the
      # whole `Apple::Foundation::U` chain. Candidates must therefore carry
      # the full receiver prefix or Reline silently rejects them.
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

        # 標準補完経路を TypeCompletor (AST/RBS, constant enumerate 無し) に切替。
        # repl_type_completor が無ければ IRB は warn して RegexpCompletor に
        # fallback するが、 RegexpCompletor は SEGV するので Completor base には
        # 渡さず @base = nil にする。
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

        # IRB::Context.build_completor を prepend で wrap。 super で base を取って
        # Completor で wrap (Apple:: は provider、 他は base にデリゲート)。
        unless ::IRB::Context.include?(ContextOverride)
          ::IRB::Context.prepend(ContextOverride)
        end

        # IRB::RelineInputMethod#initialize の super 後に :show_doc dialog を
        # chain する prepend。 hover prefetch は DocDialog#render の中で
        # Prefetcher が走るので、 Tab 確定時の同期 discovery は不要。
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

      # Internal — accessed by ContextOverride / RelineInputMethodOverride.
      attr_reader :apple_provider, :apple_doc_dialog,
                  :apple_prefetcher, :apple_llm_resolver

      private

      # Soft-load foundation_model_mac and wrap AppleFoundationModel.generate
      # in an LLMResolver. Returns nil when APPLE_IRB_NO_LLM=1 (user opt-out)
      # or the LLM gem is unavailable.
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
          # super may return RegexpCompletor (TypeCompletor unavailable, fallback);
          # do not wrap it — Apple-only mode (RegexpCompletor would SEGV under Box).
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
          # Chain :show_doc — Apple SDK doc first, IRB RDoc fallback.
          # Apple's DocDialog renders KB-sourced text + fires prefetch.
          # When that returns nil (non-Apple input), we restore the
          # popped Reline context and re-run IRB's original show_doc
          # under a StandardError rescue so RDoc 7.2 Marshal mismatches
          # are swallowed (the popup stays empty rather than leaking
          # RDoc::Store#load_class_data into the prompt).
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
