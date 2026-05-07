# irb autocomplete Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Apple SDK のクラス / 関数 / 定数 / メソッドを IRB の TAB 補完に対応させ、 method 確定瞬間に `Apple.discover` を sync 実行して LLMGenerator で shape を推論する。

**Architecture:** spec doc (`docs/superpowers/specs/2026-05-07-irb-autocomplete-design.md`) の A1 (sync on-TAB + spinner) を採用。 5 unit (`Context.parse` / `CandidateProvider` / `Spinner` / `AutoDiscoverer` / Reline hook) を `lib/apple_sdk_mac/irb_completion.rb` 1 ファイルに集約、 `lib/apple_sdk_mac.rb` 末尾に IRB 検出時のみ require を追加する。 KnowledgeCache に `list_klass_methods` を 1 メソッド追加 (parent_id JOIN)。

**Tech Stack:** Ruby 4.x master, Test::Unit, Reline (IRB), KnowledgeCache (sqlite3), 既存 LLMGenerator pipeline

---

## File Structure

```
lib/apple_sdk_mac/
  irb_completion.rb              [new]   ~250 LoC, 5 class in 1 module
  knowledge_cache.rb             [edit]  +list_klass_methods (~12 LoC)
lib/apple_sdk_mac.rb             [edit]  +1 conditional require

test/
  irb_completion/
    context_test.rb              [new]   T1
    candidate_provider_test.rb   [new]   T3
    spinner_test.rb              [new]   T4
    auto_discoverer_test.rb      [new]   T5
    install_test.rb              [new]   T6
  knowledge_cache_test.rb        [edit]  +list_klass_methods test (T2)

examples/
  irb_completion_demo.rb         [new]   T7

README.md                        [edit]  +"IRB autocomplete" section (T8)
```

---

## Task 1: Context.parse

**Files:**
- Create: `lib/apple_sdk_mac/irb_completion.rb`
- Create: `test/irb_completion/context_test.rb`

- [ ] **Step 1.1: Write the failing test**

`test/irb_completion/context_test.rb`:

```ruby
# frozen_string_literal: true
require "test_helper"
require "apple_sdk_mac/irb_completion"

class TestIRBCompletionContext < Test::Unit::TestCase
  Context = AppleSDKMac::IRBCompletion::Context

  def test_apple_root_empty
    c = Context.parse("Apple::")
    assert_equal :apple_root, c.receiver_kind
    assert_nil c.framework
    assert_nil c.klass
    assert_equal "", c.prefix
  end

  def test_apple_root_with_prefix
    c = Context.parse("Apple::Fou")
    assert_equal :apple_root, c.receiver_kind
    assert_equal "Fou", c.prefix
  end

  def test_module_empty_prefix
    c = Context.parse("Apple::Foundation::")
    assert_equal :module, c.receiver_kind
    assert_equal "Foundation", c.framework
    assert_nil c.klass
    assert_equal "", c.prefix
  end

  def test_module_with_prefix
    c = Context.parse("Apple::Foundation::NSDa")
    assert_equal :module, c.receiver_kind
    assert_equal "Foundation", c.framework
    assert_equal "NSDa", c.prefix
  end

  def test_class_empty_prefix
    c = Context.parse("Apple::Foundation::NSData.")
    assert_equal :class, c.receiver_kind
    assert_equal "Foundation", c.framework
    assert_equal "NSData", c.klass
    assert_equal "", c.prefix
  end

  def test_class_with_prefix
    c = Context.parse("Apple::Foundation::NSData.dataW")
    assert_equal :class, c.receiver_kind
    assert_equal "Foundation", c.framework
    assert_equal "NSData", c.klass
    assert_equal "dataW", c.prefix
  end

  def test_non_apple_returns_nil
    assert_nil Context.parse("String.")
    assert_nil Context.parse("foo.bar")
    assert_nil Context.parse("")
    assert_nil Context.parse(nil)
  end
end
```

- [ ] **Step 1.2: Verify RED**

```bash
bundle exec rake test TEST=test/irb_completion/context_test.rb
```

Expected: `cannot load such file -- apple_sdk_mac/irb_completion (LoadError)` または `NameError: uninitialized constant`

- [ ] **Step 1.3: Commit RED**

```bash
git add test/irb_completion/context_test.rb
git commit -m "test: T_irb1 RED — Context.parse 6 input patterns"
```

- [ ] **Step 1.4: Write minimal GREEN impl**

`lib/apple_sdk_mac/irb_completion.rb`:

```ruby
# frozen_string_literal: true

module AppleSDKMac
  module IRBCompletion
    Context = Struct.new(:framework, :klass, :receiver_kind, :prefix) do
      # Parse Reline input line into framework/klass/prefix.
      # Returns nil for non-Apple paths.
      #
      # Patterns:
      #   "Apple::"                            → :apple_root
      #   "Apple::Fou"                         → :apple_root + prefix
      #   "Apple::Foundation::"                → :module
      #   "Apple::Foundation::NSDa"            → :module + prefix
      #   "Apple::Foundation::NSData."         → :class
      #   "Apple::Foundation::NSData.dataW"    → :class + prefix
      def self.parse(input)
        return nil unless input.is_a?(String)
        return nil unless input.start_with?("Apple::")
        rest = input[7..]

        # apple_root: "" or single token (incomplete framework name)
        if rest.empty? || rest.match?(/\A[A-Z][A-Za-z0-9_]*\z/)
          return new(nil, nil, :apple_root, rest)
        end

        # module: "Foundation::" or "Foundation::NSDa"
        if (m = rest.match(/\A([A-Z][A-Za-z0-9_]*)::([A-Za-z0-9_]*)\z/))
          return new(m[1], nil, :module, m[2])
        end

        # class: "Foundation::NSData." or "Foundation::NSData.dataW"
        if (m = rest.match(/\A([A-Z][A-Za-z0-9_]*)::([A-Z][A-Za-z0-9_]*)\.([A-Za-z0-9_]*)\z/))
          return new(m[1], m[2], :class, m[3])
        end

        nil
      end
    end
  end
end
```

- [ ] **Step 1.5: Verify GREEN**

```bash
bundle exec rake test TEST=test/irb_completion/context_test.rb
```

Expected: `7 tests, 17+ assertions, 0 failures, 0 errors`

- [ ] **Step 1.6: Commit GREEN**

```bash
git add lib/apple_sdk_mac/irb_completion.rb
git commit -m "feat: T_irb1 GREEN — Context.parse for IRB completion"
```

---

## Task 2: KnowledgeCache.list_klass_methods

KnowledgeCache に新 method 追加。 `parent_id` JOIN で class の instance/class method を引く。

**Files:**
- Modify: `lib/apple_sdk_mac/knowledge_cache.rb`
- Modify: `test/knowledge_cache_test.rb`

- [ ] **Step 2.1: Write the failing test**

`test/knowledge_cache_test.rb` の最後に追加:

```ruby
  def test_list_klass_methods_returns_methods_with_parent_class
    cache = AppleSDKMac.knowledge_cache
    rows = cache.list_klass_methods(framework: "Foundation", klass: "NSString")
    # NSString は instance/class method を多数持つ。 ゼロは異常。
    assert_operator rows.size, :>=, 1, "NSString must have at least 1 child method"
    rows.each do |r|
      assert r.key?(:name)
      assert r.key?(:kind)
    end
  end

  def test_list_klass_methods_unknown_klass_empty
    cache = AppleSDKMac.knowledge_cache
    rows = cache.list_klass_methods(framework: "Foundation", klass: "ClassThatDoesNotExist__")
    assert_equal [], rows
  end
```

- [ ] **Step 2.2: Verify RED**

```bash
bundle exec rake test TEST=test/knowledge_cache_test.rb
```

Expected: `NoMethodError: undefined method 'list_klass_methods'`

- [ ] **Step 2.3: Commit RED**

```bash
git add test/knowledge_cache_test.rb
git commit -m "test: T_irb2 RED — KnowledgeCache.list_klass_methods"
```

- [ ] **Step 2.4: Write minimal GREEN impl**

`lib/apple_sdk_mac/knowledge_cache.rb`:

L66 (`def list_frameworks` の上) に新 method を挿入:

```ruby
    # Children of a class symbol — instance methods, class methods, properties.
    # IRB completion で `Apple::Foundation::NSData.<TAB>` が呼べる候補列挙に使う。
    def list_klass_methods(framework:, klass:)
      sql = <<~SQL
        SELECT s.name, s.kind, s.signature
        FROM symbols s
        JOIN symbols p ON s.parent_id = p.id
        JOIN frameworks f ON s.framework_id = f.id
        WHERE f.name = ? AND p.name = ?
      SQL
      @db.execute(sql, [framework, klass]).map do |r|
        { name: r[0], kind: r[1], signature: r[2] }
      end
    end

```

- [ ] **Step 2.5: Verify GREEN**

```bash
bundle exec rake test TEST=test/knowledge_cache_test.rb
```

Expected: 全 GREEN, NSString から 1+ method 取得

- [ ] **Step 2.6: Commit GREEN**

```bash
git add lib/apple_sdk_mac/knowledge_cache.rb
git commit -m "feat: T_irb2 GREEN — KnowledgeCache.list_klass_methods (parent_id JOIN)"
```

---

## Task 3: CandidateProvider

**Files:**
- Modify: `lib/apple_sdk_mac/irb_completion.rb`
- Create: `test/irb_completion/candidate_provider_test.rb`

- [ ] **Step 3.1: Write the failing test**

`test/irb_completion/candidate_provider_test.rb`:

```ruby
# frozen_string_literal: true
require "test_helper"
require "apple_sdk_mac/irb_completion"

class TestIRBCompletionCandidateProvider < Test::Unit::TestCase
  Context = AppleSDKMac::IRBCompletion::Context
  CandidateProvider = AppleSDKMac::IRBCompletion::CandidateProvider

  class FakeKnowledgeCache
    def initialize(frameworks: [], symbols: {}, klass_methods: {})
      @frameworks = frameworks
      @symbols = symbols
      @klass_methods = klass_methods
    end

    def list_frameworks
      @frameworks
    end

    def list_framework_symbols(framework:, kinds: nil)
      rows = @symbols[framework] || []
      rows = rows.select { |r| Array(kinds).include?(r[:kind]) } if kinds
      rows
    end

    def list_klass_methods(framework:, klass:)
      @klass_methods[[framework, klass]] || []
    end
  end

  def test_apple_root_lists_frameworks_uppercase_only
    cache = FakeKnowledgeCache.new(frameworks: ["Foundation", "Vision", "_Internal"])
    ctx = Context.parse("Apple::")
    out = CandidateProvider.new(knowledge_cache: cache).call(ctx)
    assert_equal ["Foundation", "Vision"], out.sort
  end

  def test_apple_root_with_prefix_filters
    cache = FakeKnowledgeCache.new(frameworks: ["Foundation", "FileProvider", "Vision"])
    ctx = Context.parse("Apple::F")
    out = CandidateProvider.new(knowledge_cache: cache).call(ctx)
    assert_equal ["FileProvider", "Foundation"], out.sort
  end

  def test_module_lists_class_kind_constants_with_prefix
    cache = FakeKnowledgeCache.new(symbols: {
      "Foundation" => [
        {name: "NSData", kind: "class"},
        {name: "NSString", kind: "class"},
        {name: "NSCalendar", kind: "class"},
        {name: "kCFAllocatorDefault", kind: "global_constant"}
      ]
    })
    ctx = Context.parse("Apple::Foundation::NS")
    out = CandidateProvider.new(knowledge_cache: cache).call(ctx)
    assert_equal ["NSCalendar", "NSData", "NSString"], out.sort
  end

  def test_class_lists_methods_via_list_klass_methods
    cache = FakeKnowledgeCache.new(klass_methods: {
      ["Foundation", "NSData"] => [
        {name: "dataWithContentsOfFile:", kind: "objc_method_class"},
        {name: "length", kind: "objc_method_instance"},
        {name: "bytes", kind: "objc_method_instance"}
      ]
    })
    ctx = Context.parse("Apple::Foundation::NSData.")
    out = CandidateProvider.new(knowledge_cache: cache).call(ctx)
    assert_includes out, "dataWithContentsOfFile"
    assert_includes out, "length"
    assert_includes out, "bytes"
  end

  def test_class_with_prefix_filters_methods
    cache = FakeKnowledgeCache.new(klass_methods: {
      ["Foundation", "NSData"] => [
        {name: "dataWithContentsOfFile:", kind: "objc_method_class"},
        {name: "dataWithContentsOfURL:", kind: "objc_method_class"},
        {name: "length", kind: "objc_method_instance"}
      ]
    })
    ctx = Context.parse("Apple::Foundation::NSData.dataW")
    out = CandidateProvider.new(knowledge_cache: cache).call(ctx)
    assert_equal ["dataWithContentsOfFile", "dataWithContentsOfURL"], out.sort
  end

  def test_caps_at_100
    rows = (1..150).map { |i| {name: "method#{i}", kind: "objc_method_instance"} }
    cache = FakeKnowledgeCache.new(klass_methods: {["Foundation", "NSData"] => rows})
    ctx = Context.parse("Apple::Foundation::NSData.")
    out = CandidateProvider.new(knowledge_cache: cache).call(ctx)
    assert_equal 100, out.size
  end
end
```

- [ ] **Step 3.2: Verify RED**

```bash
bundle exec rake test TEST=test/irb_completion/candidate_provider_test.rb
```

Expected: `NameError: uninitialized constant AppleSDKMac::IRBCompletion::CandidateProvider`

- [ ] **Step 3.3: Commit RED**

```bash
git add test/irb_completion/candidate_provider_test.rb
git commit -m "test: T_irb3 RED — CandidateProvider 6 cases"
```

- [ ] **Step 3.4: Write minimal GREEN impl**

`lib/apple_sdk_mac/irb_completion.rb` の `Context` 定義の **後ろ** に追加:

```ruby
    # Selector 末尾の `:` を strip + 第1 segment のみ残す形に正規化。
    # IRB 補完候補は Ruby method 名形 (`dataWithContentsOfFile`) で出す。
    SELECTOR_RE = /\A([A-Za-z_][A-Za-z0-9_]*).*/.freeze

    MODULE_KINDS = %w[
      class struct protocol enum_module function swift_func global_constant actor
    ].freeze

    KLASS_METHOD_KINDS = %w[
      objc_method_instance objc_method_class swift_init swift_property
      class_method instance_method
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
        # ObjC selector "dataWithContentsOfFile:" → "dataWithContentsOfFile"
        # multi-arg "initWithCGImage:options:" → "initWithCGImage" (first segment)
        m = symbol_name.match(SELECTOR_RE)
        m ? m[1] : symbol_name
      end
    end
```

- [ ] **Step 3.5: Verify GREEN**

```bash
bundle exec rake test TEST=test/irb_completion/candidate_provider_test.rb
```

Expected: `6 tests, 0 failures`

- [ ] **Step 3.6: Commit GREEN**

```bash
git add lib/apple_sdk_mac/irb_completion.rb
git commit -m "feat: T_irb3 GREEN — CandidateProvider with prefix + cap 100"
```

---

## Task 4: Spinner

**Files:**
- Modify: `lib/apple_sdk_mac/irb_completion.rb`
- Create: `test/irb_completion/spinner_test.rb`

- [ ] **Step 4.1: Write the failing test**

`test/irb_completion/spinner_test.rb`:

```ruby
# frozen_string_literal: true
require "test_helper"
require "apple_sdk_mac/irb_completion"
require "stringio"

class TestIRBCompletionSpinner < Test::Unit::TestCase
  Spinner = AppleSDKMac::IRBCompletion::Spinner

  class FakeTTY < StringIO
    def tty?; true; end
  end

  def test_writes_alternating_frames
    io = FakeTTY.new
    spinner = Spinner.new(io: io, interval: 0.01)
    spinner.start("discovering Foo.bar...")
    sleep 0.05
    spinner.stop

    out = io.string
    assert_match(/\* discovering Foo\.bar\.\.\./, out)
    assert_match(/\+ discovering Foo\.bar\.\.\./, out)
  end

  def test_stop_clears_line
    io = FakeTTY.new
    spinner = Spinner.new(io: io, interval: 0.01)
    spinner.start("x")
    sleep 0.02
    spinner.stop

    # 最後の write は line clear (\r + ANSI EL `\e[K` or 同等)
    assert_match(/\r\e\[K/, io.string.split.last(2).join)
  end

  def test_no_op_on_non_tty
    io = StringIO.new  # tty? returns false by default
    spinner = Spinner.new(io: io, interval: 0.01)
    spinner.start("x")
    sleep 0.02
    spinner.stop
    assert_equal "", io.string
  end

  def test_double_stop_safe
    io = FakeTTY.new
    spinner = Spinner.new(io: io, interval: 0.01)
    spinner.start("x")
    spinner.stop
    spinner.stop  # must not raise
  end
end
```

- [ ] **Step 4.2: Verify RED**

```bash
bundle exec rake test TEST=test/irb_completion/spinner_test.rb
```

Expected: `NameError: uninitialized constant AppleSDKMac::IRBCompletion::Spinner`

- [ ] **Step 4.3: Commit RED**

```bash
git add test/irb_completion/spinner_test.rb
git commit -m "test: T_irb4 RED — Spinner frame sequence + tty gate + double-stop"
```

- [ ] **Step 4.4: Write minimal GREEN impl**

`lib/apple_sdk_mac/irb_completion.rb` の `CandidateProvider` の後ろに追加:

```ruby
    # Claude Code 風 progress spinner — 100ms 周期で `*` / `+` を交互に出す。
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
```

- [ ] **Step 4.5: Verify GREEN**

```bash
bundle exec rake test TEST=test/irb_completion/spinner_test.rb
```

Expected: `4 tests, 0 failures`

- [ ] **Step 4.6: Commit GREEN**

```bash
git add lib/apple_sdk_mac/irb_completion.rb
git commit -m "feat: T_irb4 GREEN — Spinner with * + frames, tty gate, safe double-stop"
```

---

## Task 5: AutoDiscoverer

**Files:**
- Modify: `lib/apple_sdk_mac/irb_completion.rb`
- Create: `test/irb_completion/auto_discoverer_test.rb`

- [ ] **Step 5.1: Write the failing test**

`test/irb_completion/auto_discoverer_test.rb`:

```ruby
# frozen_string_literal: true
require "test_helper"
require "apple_sdk_mac/irb_completion"

class TestIRBCompletionAutoDiscoverer < Test::Unit::TestCase
  Context = AppleSDKMac::IRBCompletion::Context
  AutoDiscoverer = AppleSDKMac::IRBCompletion::AutoDiscoverer

  class FakeKnowledgeCache
    def initialize(klass_methods: {})
      @klass_methods = klass_methods
    end
    def list_klass_methods(framework:, klass:)
      @klass_methods[[framework, klass]] || []
    end
  end

  def test_module_kind_is_no_op
    # :module 経路は eager NamespaceBuilder で install 済 → discover 不要
    calls = []
    discoverer = AutoDiscoverer.new(
      knowledge_cache: FakeKnowledgeCache.new,
      discover_proc: ->(**args) { calls << args }
    )
    ctx = Context.parse("Apple::Foundation::NSData")  # :module path (no trailing ::)
    # build a synthetic module-context to exercise the no-op path explicitly
    mod_ctx = Context.new("Foundation", nil, :module, "NSData")
    discoverer.run(mod_ctx, "NSData")
    assert_equal [], calls
  end

  def test_class_method_dispatches_class_method_form
    cache = FakeKnowledgeCache.new(klass_methods: {
      ["Foundation", "NSData"] => [
        {name: "dataWithContentsOfFile:", kind: "objc_method_class"}
      ]
    })
    calls = []
    discoverer = AutoDiscoverer.new(
      knowledge_cache: cache,
      discover_proc: ->(**args) { calls << args }
    )
    ctx = Context.parse("Apple::Foundation::NSData.dataWithContentsOfFile")
    discoverer.run(ctx, "dataWithContentsOfFile")

    assert_equal 1, calls.size
    assert_equal :Foundation, calls.first[:framework]
    assert_equal :NSData, calls.first[:klass]
    assert_equal "dataWithContentsOfFile:", calls.first[:class_method]
  end

  def test_instance_method_dispatches_selector_form
    cache = FakeKnowledgeCache.new(klass_methods: {
      ["Foundation", "NSData"] => [
        {name: "length", kind: "objc_method_instance"}
      ]
    })
    calls = []
    discoverer = AutoDiscoverer.new(
      knowledge_cache: cache,
      discover_proc: ->(**args) { calls << args }
    )
    ctx = Context.parse("Apple::Foundation::NSData.length")
    discoverer.run(ctx, "length")

    assert_equal 1, calls.size
    assert_equal "length", calls.first[:selector]
  end

  def test_swift_init_dispatches_swift_initializer_form
    cache = FakeKnowledgeCache.new(klass_methods: {
      ["Vision", "VNRecognizeTextRequest"] => [
        {name: "init()", kind: "swift_init", signature: "init()"}
      ]
    })
    calls = []
    discoverer = AutoDiscoverer.new(
      knowledge_cache: cache,
      discover_proc: ->(**args) { calls << args }
    )
    ctx = Context.parse("Apple::Vision::VNRecognizeTextRequest.init")
    discoverer.run(ctx, "init")

    assert_equal 1, calls.size
    assert_equal "init()", calls.first[:swift_initializer]
  end

  def test_swift_property_dispatches_swift_property_form
    cache = FakeKnowledgeCache.new(klass_methods: {
      ["Vision", "VNRecognizedText"] => [
        {name: "string", kind: "swift_property"}
      ]
    })
    calls = []
    discoverer = AutoDiscoverer.new(
      knowledge_cache: cache,
      discover_proc: ->(**args) { calls << args }
    )
    ctx = Context.parse("Apple::Vision::VNRecognizedText.string")
    discoverer.run(ctx, "string")

    assert_equal 1, calls.size
    assert_equal :string, calls.first[:swift_property]
    assert_equal true, calls.first[:instance]
  end

  def test_unknown_method_no_op
    # KB に該当 method 無し → 何も呼ばない (silent skip)。 user 入力ミスの保護。
    calls = []
    discoverer = AutoDiscoverer.new(
      knowledge_cache: FakeKnowledgeCache.new,
      discover_proc: ->(**args) { calls << args }
    )
    ctx = Context.parse("Apple::Foundation::NSData.bogusMethod")
    discoverer.run(ctx, "bogusMethod")
    assert_equal [], calls
  end

  def test_discover_failure_propagates
    cache = FakeKnowledgeCache.new(klass_methods: {
      ["Foundation", "NSData"] => [
        {name: "length", kind: "objc_method_instance"}
      ]
    })
    discoverer = AutoDiscoverer.new(
      knowledge_cache: cache,
      discover_proc: ->(**) { raise AppleSDKMac::CompileError, "boom" }
    )
    ctx = Context.parse("Apple::Foundation::NSData.length")
    assert_raise(AppleSDKMac::CompileError) do
      discoverer.run(ctx, "length")
    end
  end
end
```

- [ ] **Step 5.2: Verify RED**

```bash
bundle exec rake test TEST=test/irb_completion/auto_discoverer_test.rb
```

Expected: `NameError: uninitialized constant AppleSDKMac::IRBCompletion::AutoDiscoverer`

- [ ] **Step 5.3: Commit RED**

```bash
git add test/irb_completion/auto_discoverer_test.rb
git commit -m "test: T_irb5 RED — AutoDiscoverer kind→discover keyword routing 7 cases"
```

- [ ] **Step 5.4: Write minimal GREEN impl**

`lib/apple_sdk_mac/irb_completion.rb` の `Spinner` の後ろに追加:

```ruby
    # 補完で確定した method 名を Apple.discover の正しい keyword shape に
    # マッピングして同期実行する。 parameters / return_kind は明示せず、
    # TemplateGenerator → LLMGenerator pipeline に shape 推論させる。
    class AutoDiscoverer
      def initialize(knowledge_cache:, discover_proc: nil)
        @cache = knowledge_cache
        @discover = discover_proc || ->(**args) { ::Apple.discover(**args) }
      end

      def run(context, chosen_name)
        return if context.nil?
        return if context.receiver_kind != :class  # :module/:apple_root は build! 範囲

        record = lookup_method_record(context, chosen_name)
        return if record.nil?  # KB に該当無し: user typo 等は silent skip

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
```

- [ ] **Step 5.5: Verify GREEN**

```bash
bundle exec rake test TEST=test/irb_completion/auto_discoverer_test.rb
```

Expected: `7 tests, 0 failures`

- [ ] **Step 5.6: Commit GREEN**

```bash
git add lib/apple_sdk_mac/irb_completion.rb
git commit -m "feat: T_irb5 GREEN — AutoDiscoverer routes kind to discover keyword shape"
```

---

## Task 6: IRBCompletion.install! (Reline hook)

**Files:**
- Modify: `lib/apple_sdk_mac/irb_completion.rb`
- Modify: `lib/apple_sdk_mac.rb`
- Create: `test/irb_completion/install_test.rb`

- [ ] **Step 6.1: Write the failing test**

`test/irb_completion/install_test.rb`:

```ruby
# frozen_string_literal: true
require "test_helper"
require "reline"
require "apple_sdk_mac/irb_completion"

class TestIRBCompletionInstall < Test::Unit::TestCase
  def setup
    @original_proc = Reline.completion_proc
    @original_perfect = Reline.dig_perfect_match_proc
  end

  def teardown
    AppleSDKMac::IRBCompletion.uninstall!
    Reline.completion_proc = @original_proc
    Reline.dig_perfect_match_proc = @original_perfect
  end

  def test_install_replaces_completion_proc
    AppleSDKMac::IRBCompletion.install!
    refute_same @original_proc, Reline.completion_proc
  end

  def test_apple_path_uses_apple_provider
    captured = []
    fake_cache = Object.new
    fake_cache.define_singleton_method(:list_frameworks) { ["Foundation", "Vision"] }
    fake_cache.define_singleton_method(:list_framework_symbols) { |**| [] }
    fake_cache.define_singleton_method(:list_klass_methods) { |**| [] }

    AppleSDKMac::IRBCompletion.install!(
      knowledge_cache: fake_cache,
      discover_proc: ->(**args) { captured << args }
    )
    out = Reline.completion_proc.call("Apple::")
    assert_includes out, "Foundation"
    assert_includes out, "Vision"
  end

  def test_non_apple_path_delegates_to_original
    sentinel = ["delegated_result"]
    Reline.completion_proc = ->(_) { sentinel }
    AppleSDKMac::IRBCompletion.install!
    out = Reline.completion_proc.call("String.")
    assert_equal sentinel, out
  end

  def test_uninstall_restores_original
    Reline.completion_proc = ->(_) { ["sentinel"] }
    original = Reline.completion_proc
    AppleSDKMac::IRBCompletion.install!
    AppleSDKMac::IRBCompletion.uninstall!
    assert_same original, Reline.completion_proc
  end
end
```

- [ ] **Step 6.2: Verify RED**

```bash
bundle exec rake test TEST=test/irb_completion/install_test.rb
```

Expected: `NoMethodError: undefined method 'install!' for AppleSDKMac::IRBCompletion`

- [ ] **Step 6.3: Commit RED**

```bash
git add test/irb_completion/install_test.rb
git commit -m "test: T_irb6 RED — IRBCompletion.install! Reline hook + uninstall"
```

- [ ] **Step 6.4: Write minimal GREEN impl**

`lib/apple_sdk_mac/irb_completion.rb` の最下層 (module 内 `end` の前) に追加:

```ruby
    @installed = false
    @saved_completion_proc = nil
    @saved_dig_perfect_match_proc = nil

    class << self
      def install!(knowledge_cache: nil, discover_proc: nil, spinner_io: $stderr)
        return if @installed
        require "reline"
        knowledge_cache ||= AppleSDKMac.knowledge_cache
        provider = CandidateProvider.new(knowledge_cache: knowledge_cache)
        discoverer = AutoDiscoverer.new(
          knowledge_cache: knowledge_cache,
          discover_proc: discover_proc
        )
        spinner = Spinner.new(io: spinner_io)

        @saved_completion_proc = Reline.completion_proc
        @saved_dig_perfect_match_proc = Reline.dig_perfect_match_proc
        original = @saved_completion_proc

        Reline.completion_proc = lambda do |input|
          context = Context.parse(input)
          if context
            provider.call(context)
          else
            original ? original.call(input) : []
          end
        end

        Reline.dig_perfect_match_proc = lambda do |target|
          context = Context.parse(target)
          next unless context && context.receiver_kind == :class
          message = "discovering #{context.framework}::#{context.klass}.#{context.prefix}..."
          spinner.start(message)
          begin
            discoverer.run(context, context.prefix)
          ensure
            spinner.stop
          end
        end

        @installed = true
      end

      def uninstall!
        return unless @installed
        Reline.completion_proc = @saved_completion_proc
        Reline.dig_perfect_match_proc = @saved_dig_perfect_match_proc
        @saved_completion_proc = nil
        @saved_dig_perfect_match_proc = nil
        @installed = false
      end

      def installed?
        @installed
      end
    end
```

`lib/apple_sdk_mac.rb` の最終行 (`end` の前) に追加:

```ruby

# IRB session (or test harness loading "reline") detected → enable autocomplete.
# Plain script use is unaffected (no Reline hook installed).
if defined?(IRB) || (defined?(Reline) && $0 =~ /(?:^|\/)irb\z/)
  require_relative "apple_sdk_mac/irb_completion"
  AppleSDKMac::IRBCompletion.install!
end
```

- [ ] **Step 6.5: Verify GREEN**

```bash
bundle exec rake test TEST=test/irb_completion/install_test.rb
```

Expected: `4 tests, 0 failures`

- [ ] **Step 6.6: Verify smoke 全 GREEN 維持**

`bundle exec rake test` がロングバッチ。 longrun pattern で:

```bash
mkdir -p tmp/longrun && screen -dmS smoke-T_irb6 bash -c '
  cd /Users/bash/dev/src/github.com/bash0C7/rb-apple-sdk-mac
  bundle exec rake test > tmp/longrun/smoke-T_irb6.log 2>&1
  echo "DONE: exit=$?" >> tmp/longrun/smoke-T_irb6.log
'
```

待機後:

```bash
grep "^DONE:" tmp/longrun/smoke-T_irb6.log
tail -8 tmp/longrun/smoke-T_irb6.log
```

Expected: `DONE: exit=0`、 `0 failures, 0 errors`

- [ ] **Step 6.7: Commit GREEN**

```bash
git add lib/apple_sdk_mac/irb_completion.rb lib/apple_sdk_mac.rb
git commit -m "feat: T_irb6 GREEN — IRBCompletion.install! Reline hook + auto-load"
```

---

## Task 7: examples/irb_completion_demo.rb

**Files:**
- Create: `examples/irb_completion_demo.rb`

- [ ] **Step 7.1: Write demo script (no separate RED — example は assertion 内蔵)**

`examples/irb_completion_demo.rb`:

```ruby
# frozen_string_literal: true
# IRB autocomplete demo. Reline session を直接 simulate せず、 install! 後に
# Reline.completion_proc / Reline.dig_perfect_match_proc を直接呼んで補完候補と
# auto-discover trigger を確認する (release-quality demo: ヘッドレス検証可能)。
#
# Usage:
#   RUBY_BOX=1 bundle exec ruby examples/irb_completion_demo.rb
require "apple_sdk_mac"
require "apple_sdk_mac/irb_completion"
require "reline"

AppleSDKMac::IRBCompletion.install!

# Phase 1: framework 列挙
out = Reline.completion_proc.call("Apple::")
raise "Phase 1: no frameworks listed" if out.empty?
puts "Phase 1: Apple:: TAB → #{out.first(5).inspect} ... (#{out.size} total)"

# Phase 2: framework 内の class 列挙
out = Reline.completion_proc.call("Apple::Foundation::NS")
raise "Phase 2: NS prefix returned no candidates" if out.empty?
puts "Phase 2: Apple::Foundation::NS TAB → #{out.first(5).inspect} ... (#{out.size} total)"

# Phase 3: class の method 列挙
out = Reline.completion_proc.call("Apple::Foundation::NSString.")
raise "Phase 3: NSString. returned no candidates" if out.empty?
puts "Phase 3: Apple::Foundation::NSString. TAB → #{out.first(5).inspect} ... (#{out.size} total)"

puts "irb_completion_demo OK"
```

- [ ] **Step 7.2: Run demo**

```bash
RUBY_BOX=1 bundle exec ruby examples/irb_completion_demo.rb
```

Expected output (with KB present):
```
Phase 1: Apple:: TAB → ["Accelerate", "Accessibility", ...] ... (XXX total)
Phase 2: Apple::Foundation::NS TAB → ["NSArray", ...] ... (XX total)
Phase 3: Apple::Foundation::NSString. TAB → ["init", "stringWithUTF8String", ...] ... (XX total)
irb_completion_demo OK
```

- [ ] **Step 7.3: Commit GREEN**

```bash
git add examples/irb_completion_demo.rb
git commit -m "feat: T_irb7 GREEN — irb_completion_demo.rb (release-quality headless demo)"
```

---

## Task 8: README 追記

**Files:**
- Modify: `README.md`

- [ ] **Step 8.1: Edit README — `## Usage` セクションの末尾に追記**

`See `examples/` for more.` の後に新セクション挿入:

```markdown

## IRB autocomplete

When loaded inside an IRB session, the gem installs a Reline completion
hook that lists Apple SDK frameworks, classes, and methods, and auto-runs
`Apple.discover` (with LLM-inferred parameter shape) when you confirm a
method name with TAB.

```
$ irb -r apple_sdk_mac
> Apple::Foundation::NSData.<TAB>
  → dataWithContentsOfFile, dataWithContentsOfURL, length, bytes, ...
> Apple::Foundation::NSData.dataWithContentsOfFile<TAB>
  * discovering Foundation::NSData.dataWithContentsOfFile...
  + discovering Foundation::NSData.dataWithContentsOfFile...
  (cursor returns once swiftc + LLM inference complete)
> Apple::Foundation::NSData.dataWithContentsOfFile("/path/to/file")
```
```

- [ ] **Step 8.2: Run smoke 1 回確認**

```bash
RUBY_BOX=1 bundle exec ruby examples/irb_completion_demo.rb
```

Expected: 引き続き OK

- [ ] **Step 8.3: Commit GREEN**

```bash
git add README.md
git commit -m "docs: T_irb8 — IRB autocomplete section in README"
```

---

## Final verification

- [ ] **Final.1: Run full smoke (longrun)**

```bash
mkdir -p tmp/longrun && screen -dmS smoke-irb-final bash -c '
  cd /Users/bash/dev/src/github.com/bash0C7/rb-apple-sdk-mac
  bundle exec rake test > tmp/longrun/smoke-irb-final.log 2>&1
  echo "DONE: exit=$?" >> tmp/longrun/smoke-irb-final.log
'
```

待機後:

```bash
grep "^DONE:" tmp/longrun/smoke-irb-final.log
tail -8 tmp/longrun/smoke-irb-final.log
```

Expected: `DONE: exit=0`, `0 failures, 0 errors`, test 件数は 231 → 231 + (新 unit test 計 ~25) ≒ 256

- [ ] **Final.2: Run all release-quality examples**

```bash
for f in examples/cf_string_create.rb examples/urlsession_download.rb \
         examples/vision_ocr.rb examples/avspeech_synth.rb \
         examples/irb_completion_demo.rb; do
  echo "=== $f ==="
  RUBY_BOX=1 bundle exec ruby "$f" || { echo "FAILED: $f"; break; }
done
```

Expected: 全例で OK 行表示、 全例 exit=0

- [ ] **Final.3: 報告**

完了報告: 「IRB autocomplete v1 完成、 smoke 緑維持 (XXX/XXX/0)、 5 example 全 GREEN」

---

## Summary

8 task, 推定 14 commit:

| Task    | RED | GREEN | Note                              |
|---------|-----|-------|-----------------------------------|
| T_irb1  | ✓   | ✓     | Context.parse                     |
| T_irb2  | ✓   | ✓     | KnowledgeCache.list_klass_methods |
| T_irb3  | ✓   | ✓     | CandidateProvider                 |
| T_irb4  | ✓   | ✓     | Spinner                           |
| T_irb5  | ✓   | ✓     | AutoDiscoverer                    |
| T_irb6  | ✓   | ✓     | install! / uninstall! + autoload  |
| T_irb7  | -   | ✓     | examples/irb_completion_demo.rb   |
| T_irb8  | -   | ✓     | README                            |

REFACTOR 不要 (各 GREEN 実装が既に最小・直接的)。 必要が出たら個別 commit で対応。
