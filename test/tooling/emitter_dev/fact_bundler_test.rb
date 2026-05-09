# frozen_string_literal: true
$LOAD_PATH.unshift File.expand_path("../../../tooling/lib", __dir__)
require "test/unit"
require "fileutils"
require "tmpdir"
require "emitter_dev/fact_bundler"

class FactBundlerTest < Test::Unit::TestCase
  def setup
    @tmp = Dir.mktmpdir
    Dir.chdir(@tmp) do
      system "git init -q --initial-branch=main"
      system "git config user.email t@x; git config user.name t"
      File.write("a", "1"); system "git add a && git commit -qm base"
      system "git checkout -qb emitter/test-fix"
      File.write("b", "2"); system "git add b && git commit -qm fix"
    end
    @prev = Dir.pwd; Dir.chdir(@tmp)
    FileUtils.mkdir_p("tmp/emitter")
    File.write("tmp/emitter/regression_emitter_test-fix.txt", "489 tests, 2105 assertions, 0 failures, 0 errors\n")
    File.write("tmp/emitter/verify_emitter_test-fix.txt",     "1 tests, 2 assertions, 0 failures, 0 errors\n")
    File.write("tmp/emitter/compile_history_emitter_test-fix.txt", "new template row: A/sym1\n")
  end

  def teardown
    Dir.chdir(@prev); FileUtils.rm_rf(@tmp)
  end

  def test_compose_includes_all_sections
    md = EmitterDev::FactBundler.new(branch: "emitter/test-fix", base: "main").compose
    assert_match(/## branch & commits/, md)
    assert_match(/## diff stat/, md)
    assert_match(/## regression/, md)
    assert_match(/489 tests/, md)
    assert_match(/## individual verification/, md)
    assert_match(/## compile_history delta/, md)
    assert_match(/new template row/, md)
  end

  def test_compose_marks_missing_artifact
    File.delete("tmp/emitter/verify_emitter_test-fix.txt")
    md = EmitterDev::FactBundler.new(branch: "emitter/test-fix", base: "main").compose
    assert_match(/<missing: tmp\/emitter\/verify_emitter_test-fix\.txt>/, md)
  end
end
