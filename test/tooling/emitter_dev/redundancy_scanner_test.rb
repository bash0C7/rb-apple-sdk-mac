# frozen_string_literal: true
$LOAD_PATH.unshift File.expand_path("../../../tooling/lib", __dir__)
require "test/unit"
require "emitter_dev/redundancy_scanner"

class RedundancyScannerTest < Test::Unit::TestCase
  def fixture_path
    File.expand_path("../../fixtures/emitter_dev/sample_marshallers.rb", __dir__)
  end

  def test_scan_detects_twin_private_helpers
    cands = EmitterDev::RedundancyScanner.new(fixture_path).scan
    twins = cands.select { |c| c[:heuristic] == :twin_private_helper }
    assert_operator twins.size, :>=, 1, "expected at least 1 twin helper detection"
    methods = twins.first[:methods]
    assert_includes methods, "scalar_type_token"
    assert_includes methods, "scalar_float_type"
  end

  def test_scan_detects_class_pair_with_overlapping_methods
    cands = EmitterDev::RedundancyScanner.new(fixture_path).scan
    pairs = cands.select { |c| c[:heuristic] == :class_pair_method_overlap }
    assert_operator pairs.size, :>=, 1
    pair = pairs.first[:classes]
    assert_includes pair, "BlockA"
    assert_includes pair, "BlockAVoid"
  end
end
