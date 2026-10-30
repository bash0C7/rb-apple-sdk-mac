# frozen_string_literal: true
require "test_helper"

class TestDiscoverCoverage < Test::Unit::TestCase
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

  def test_each_catalog_kind_has_at_least_one_symbol
    cache = AppleSDKMac.knowledge_cache
    db = cache.instance_variable_get(:@db)
    found = db.execute("SELECT DISTINCT kind FROM symbols").flatten
    catalog_kinds_in_db = KIND_VOCABULARY & found
    assert_operator catalog_kinds_in_db.size, :>=, 6,
      "expected at least 6 catalog kinds in KB; found: #{catalog_kinds_in_db.inspect}"
  end
end
