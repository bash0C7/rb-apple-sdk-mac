# frozen_string_literal: true
require "test/unit"
require "open3"
require "rbconfig"

class TestKnowledgeTopLoadHasNoProgressbar < Test::Unit::TestCase
  # The main gem's runtime path (`require "rb_apple_sdk_knowledge"`) must not
  # transitively `require "ruby-progressbar"`. The importer (only consumer)
  # is rake-task-only.
  def test_top_require_does_not_load_progressbar
    repo_root = File.expand_path("..", __dir__)
    ruby = RbConfig.ruby
    script = <<~RUBY
      $LOAD_PATH.unshift("#{repo_root}/knowledge/lib")
      $LOAD_PATH.unshift("#{repo_root}/lib")
      require "rb_apple_sdk_knowledge"
      hits = $LOADED_FEATURES.grep(/ruby-progressbar|ruby_progressbar|progress_reporter|rb_apple_sdk_knowledge\\/importer\\.rb/)
      puts hits.inspect
    RUBY
    out, status = Open3.capture2(ruby, "-e", script, chdir: repo_root)
    assert_predicate status, :success?, out
    assert_equal "[]\n", out,
      "rb_apple_sdk_knowledge top-level require must not load progressbar / progress_reporter / importer.rb top-module"
  end
end
