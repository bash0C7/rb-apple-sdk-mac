# frozen_string_literal: true

module AppleSDKMac
  module IRBCompletion
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

    # Claude Code 風 progress spinner — `*` / `+` を 100ms 周期で交互に出す。
    # tty? でない io には何も書かない (smoke / pipe redirect で汚れない)。
    class Spinner
      FRAMES = %w[* +].freeze

      def initialize(io: $stderr, interval: 0.1)
        @io = io
        @interval = interval
        @thread = nil
        @running = false
      end

      def start(message)
        return unless @io.respond_to?(:tty?) && @io.tty?
        return if @running
        @running = true
        @thread = Thread.new do
          i = 0
          while @running
            @io.write("\r#{FRAMES[i % FRAMES.size]} #{message}")
            @io.flush if @io.respond_to?(:flush)
            i += 1
            sleep @interval
          end
        end
      end

      def stop
        return unless @running
        @running = false
        @thread&.join
        @thread = nil
        @io.write("\r\e[K") if @io.respond_to?(:tty?) && @io.tty?
        @io.flush if @io.respond_to?(:flush)
      end
    end

    # 補完で確定した method 名を Apple.discover の正しい keyword shape に
    # マッピングして同期実行する。 parameters / return_kind は明示せず、
    # TemplateGenerator → LLMGenerator pipeline に shape 推論を任せる。
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
  end
end
