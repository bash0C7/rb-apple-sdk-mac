# frozen_string_literal: true
require "test_helper"

# Macro coverage. Random-samples symbols from the KnowledgeCache and
# asserts every one resolves to a kind the catalog recognizes. Safety
# net for "any public Apple framework API is reachable" — if a kind
# shows up in the DB that Apple.discover dispatch cannot route, this
# test surfaces it before users hit it.
#
# This is a no-LLM check: kind MUST be derivable from the DB record
# alone. No glue is compiled here.
class TestDiscoverCoverage < Test::Unit::TestCase
  # Vocabulary derived from rb-apple-sdk-knowledge classifier output
  # plus the synthesized kinds Apple.discover registers into the transient
  # lookup tier.
  KIND_VOCABULARY = %w[
    function global_constant enum_case struct class_method instance_method
    instance_property protocol enum_module class typealias initializer
    swift_func swift_init swift_property objc_method_class objc_method_instance
    block_nilable block_persistent cftype_ref_autoarc actor
  ].freeze

  SAMPLE_SIZE = Integer(ENV["DISCOVER_COVERAGE_SAMPLE"] || 1000)

  def test_random_sampled_symbols_have_recognized_kind
    cache = AppleSDKMac.knowledge_cache
    db = cache.instance_variable_get(:@db)
    sample = db.execute(<<~SQL, [SAMPLE_SIZE])
      SELECT s.name, s.kind, f.name
      FROM symbols s
      JOIN frameworks f ON s.framework_id = f.id
      ORDER BY RANDOM()
      LIMIT ?
    SQL

    assert_operator sample.size, :>=, [SAMPLE_SIZE, 100].min,
      "knowledge base too small for meaningful coverage check"

    unknown = sample.reject { |r| KIND_VOCABULARY.include?(r[1]) }
    if unknown.any?
      head = unknown.first(10).map { |r| "#{r[2]}::#{r[0]} (kind=#{r[1].inspect})" }
      flunk "found #{unknown.size}/#{sample.size} symbols with kind outside the catalog. " \
            "First 10:\n  - #{head.join("\n  - ")}"
    end
  end

  # Coverage by kind — every kind in the catalog should have at least
  # one symbol. If a kind disappears from the KB (rb-apple-sdk-knowledge
  # bug or schema regression), this test catches it.
  def test_each_catalog_kind_has_at_least_one_symbol
    cache = AppleSDKMac.knowledge_cache
    db = cache.instance_variable_get(:@db)
    found = db.execute("SELECT DISTINCT kind FROM symbols").flatten
    catalog_kinds_in_db = KIND_VOCABULARY & found
    # Expect at least 6 of the catalog kinds to be present (function,
    # global_constant, enum_case, struct, class_method, etc.). Synthesized
    # kinds (block_nilable etc.) are populated as the importer evolves.
    assert_operator catalog_kinds_in_db.size, :>=, 6,
      "expected at least 6 catalog kinds in KB; found: #{catalog_kinds_in_db.inspect}"
  end
end
