# frozen_string_literal: true
$LOAD_PATH.unshift File.expand_path("../../../tooling/lib", __dir__)
require "test/unit"
require "emitter_dev/candidate_ranker"

class CandidateRankerTest < Test::Unit::TestCase
  # Synthetic compile_history aggregate rows.
  # Shape matches the conceptual SELECT in spec section 5.1:
  #   framework, symbol, llm_count, tpl_count, avg_retry, error_stages
  # Task 1.6's rake task is responsible for producing these rows from SQLite;
  # this test exercises the ranker as a stateless function over pre-aggregated input.
  def aggregate_rows
    [
      {
        "framework"    => "A",
        "symbol"       => "sym1",
        "llm_count"    => 2,
        "tpl_count"    => 0,
        "avg_retry"    => 2.5,
        "error_stages" => "template_nil",
      },
      {
        "framework"    => "B",
        "symbol"       => "sym2",
        "llm_count"    => 1,
        "tpl_count"    => 0,
        "avg_retry"    => 1.0,
        "error_stages" => "swiftc",
      },
      {
        "framework"    => "C",
        "symbol"       => "sym3",
        "llm_count"    => 0,
        "tpl_count"    => 1,
        "avg_retry"    => 0.0,
        "error_stages" => nil,
      },
    ]
  end

  def test_rank_add_mode_sorts_by_score_descending
    out = EmitterDev::CandidateRanker.rank(rows: aggregate_rows, mode: "add", top: 5)
    cs  = out.fetch("candidates")
    assert_equal 2, cs.size
    assert_equal "sym1", cs[0].fetch("evidence").fetch("compile_history").fetch("symbol")
    assert_equal "add", cs[0].fetch("mode")
    assert cs[0].fetch("score") > cs[1].fetch("score"), "sym1 should outrank sym2"
  end

  def test_rank_excludes_template_only_symbols
    out = EmitterDev::CandidateRanker.rank(rows: aggregate_rows, mode: "add", top: 5)
    syms = out.fetch("candidates").map { |c| c.fetch("evidence").fetch("compile_history").fetch("symbol") }
    refute_includes syms, "sym3"
  end

  def test_rank_assigns_sequential_ids_from_one
    out = EmitterDev::CandidateRanker.rank(rows: aggregate_rows, mode: "add", top: 5)
    ids = out.fetch("candidates").map { |c| c.fetch("id") }
    assert_equal [1, 2], ids
  end

  def test_rank_respects_top_n
    out = EmitterDev::CandidateRanker.rank(rows: aggregate_rows, mode: "add", top: 1)
    assert_equal 1, out.fetch("candidates").size
    assert_equal "sym1", out.fetch("candidates").first.fetch("evidence").fetch("compile_history").fetch("symbol")
  end

  def test_rank_envelope_echoes_mode_and_top
    out = EmitterDev::CandidateRanker.rank(rows: aggregate_rows, mode: "add", top: 5)
    assert_equal "add", out.fetch("mode")
    assert_equal 5, out.fetch("top")
    assert_match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/, out.fetch("generated_at"))
  end

  def synthetic_findings
    [
      {
        heuristic: :twin_private_helper,
        classes:   ["IntMarshaller", "FloatMarshaller"],
        methods:   ["scalar_type_token", "scalar_float_type"],
        score:     12,
      },
      {
        heuristic:      :class_pair_method_overlap,
        classes:        ["BlockA", "BlockAVoid"],
        common_methods: ["in_load", "call_arg"],
        score:          10,
      },
    ]
  end

  def test_rank_trim_mode_returns_redundancy_candidates
    out = EmitterDev::CandidateRanker.rank(
      rows: [], findings: synthetic_findings, mode: "trim", top: 5,
    )
    cs = out.fetch("candidates")
    assert_equal 2, cs.size
    assert_equal "trim", cs[0].fetch("mode")
    assert cs[0].fetch("evidence").key?("redundancy_scanner"),
           "trim candidate evidence must carry redundancy_scanner key"
    assert cs[0].fetch("score") >= cs[1].fetch("score"),
           "trim candidates must be sorted by score descending"
  end

  def test_rank_all_mode_merges_add_and_trim
    out = EmitterDev::CandidateRanker.rank(
      rows: aggregate_rows, findings: synthetic_findings, mode: "all", top: 10,
    )
    modes = out.fetch("candidates").map { |c| c.fetch("mode") }
    assert_includes modes, "add"
    assert_includes modes, "trim"
  end

  def test_rank_score_includes_template_nil_bonus
    rows_with_template_nil = [
      {
        "framework" => "X", "symbol" => "with_nil",
        "llm_count" => 1, "tpl_count" => 0, "avg_retry" => 0.0,
        "error_stages" => "template_nil",
      },
      {
        "framework" => "Y", "symbol" => "without_nil",
        "llm_count" => 1, "tpl_count" => 0, "avg_retry" => 0.0,
        "error_stages" => "swiftc",
      },
    ]
    out = EmitterDev::CandidateRanker.rank(rows: rows_with_template_nil, mode: "add", top: 5)
    cs  = out.fetch("candidates")
    with_nil    = cs.find { |c| c.fetch("evidence").fetch("compile_history").fetch("symbol") == "with_nil" }
    without_nil = cs.find { |c| c.fetch("evidence").fetch("compile_history").fetch("symbol") == "without_nil" }
    assert with_nil.fetch("score") > without_nil.fetch("score"),
           "template_nil error_stage should add +5 to score"
  end
end
