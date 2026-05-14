# frozen_string_literal: true
require "test-unit"
require "sqlite3"
require "apple_sdk_mac/errors"
require "apple_sdk_mac/glue_compiler/template_generator"

# ruby-progressbar is not in the Gemfile (importer-only dependency).
# Intercept the require so loading rb_apple_sdk_knowledge does not
# abort with LoadError in parallel-session environments where the gem
# is absent from the active bundle.
module Kernel
  alias_method :__phase2_smoke_original_require__, :require
  def require(name)
    return true if name == "ruby-progressbar"
    __phase2_smoke_original_require__(name)
  end
  private :require
end

KNOWLEDGE_DB = File.expand_path(
  "../../.rb-apple-sdk-mac/knowledge/26.4.1/sdk_knowledge.sqlite",
  __dir__
).freeze

class TestEmitterPhase2Smoke < Test::Unit::TestCase
  def setup
    omit "Knowledge Base sqlite 未 build (skip phase 2 smoke)" unless File.exist?(KNOWLEDGE_DB)
    require "rb_apple_sdk_knowledge/store"
    require "apple_sdk_mac/knowledge_cache"
    store = AppleSDKKnowledge::Store.open(KNOWLEDGE_DB)
    @kc = AppleSDKMac::KnowledgeCache.new(store)
    @tg = AppleSDKMac::GlueCompiler::TemplateGenerator.new(knowledge_cache: @kc)
  end

  def teardown
    @kc&.close
  end

  # Smoke 1: throws init emitter path — register_transient で AVAudioFile.init(forReading:)
  # を is_throws=true で Knowledge Base に inject し、 do/catch + rb_raise dispatch を
  # emit することを確認。 real Knowledge Base に swift_init kind の is_throws record は
  # 現行 schema に未収録のため transient 注入でエンドツーエンドを smoke する。
  def test_smoke_throws_init_emits_do_catch
    @kc.register_transient(
      framework: "AVFoundation",
      symbol: "AVAudioFile.init(forReading:)",
      record: { is_throws: true, is_failable: false, is_async: false, unsupported_pattern: nil }
    )
    swift = @tg.generate(
      framework: "AVFoundation",
      symbol: {
        kind: "swift_init",
        name: "AVAudioFile.init(forReading:)",
        swift_class: "AVAudioFile",
        swift_initializer: "init(forReading:)",
        params: [:opaque_ref],
        return_kind: :opaque_ref
      },
      glue_id: "smoketest"
    )
    assert_not_nil swift, "Phase 2 emitter should produce Swift source for throws init"
    assert_match(/do \{/, swift, "throws init emits do block")
    assert_match(/try AVAudioFile\(/, swift)
    assert_match(/rb_raise\(/, swift, "catch block should rb_raise")
    assert_no_match(/guard let v = try\? /, swift, "try? silent swallow must be eliminated")
  ensure
    @kc&.clear_transient!
  end

  # Smoke 2: real Knowledge Base に存在する swift_macro marked symbol (Phase 1 で
  # 3290 件 unsupported_pattern marked) を動的に 1 件取得し、 generate が
  # UnsupportedPatternError を raise することを確認。
  def test_smoke_unsupported_pattern_swift_macro_raises
    db = SQLite3::Database.new(knowledge_db_path)
    db.results_as_hash = false
    row = db.execute(<<~SQL).first
      SELECT s.name, f.name AS fw_name
      FROM symbols s
      JOIN frameworks f ON s.framework_id = f.id
      WHERE s.unsupported_pattern = 'swift_macro'
      LIMIT 1
    SQL
    db.close
    omit "no swift_macro marked symbol in Knowledge Base" unless row
    symbol_name = row[0]
    framework_name = row[1]

    err = assert_raise(AppleSDKMac::UnsupportedPatternError) do
      @tg.generate(
        framework: framework_name,
        symbol: {
          kind: "swift_func",
          name: symbol_name,
          swift_class: symbol_name.split(".").first,
          swift_func: symbol_name.split(".").last,
          params: [],
          return_kind: :void
        },
        glue_id: "smoketest"
      )
    end
    assert_equal "swift_macro", err.pattern
    assert_equal framework_name, err.framework
    assert_match(/Swift package wrapping/, err.message,
      "swift_macro pattern hint should suggest Swift package wrapper workaround")
  end

  private

  def knowledge_db_path
    KNOWLEDGE_DB
  end
end
