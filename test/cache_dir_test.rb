# frozen_string_literal: true
require "test/unit"
require "apple_sdk_mac/cache_dir"
require "tmpdir"

class CacheDirTest < Test::Unit::TestCase
  def test_returns_bundler_root_when_loaded
    omit "Bundler.root not available" unless defined?(Bundler) && Bundler.respond_to?(:root)
    expected = File.join(Bundler.root.to_s, ".rb-apple-sdk-mac")
    assert_equal expected, AppleSDKMac.cache_dir
  end

  def test_walks_up_from_pwd_to_find_gemfile
    Dir.mktmpdir do |root|
      File.write(File.join(root, "Gemfile"), "")
      sub = File.join(root, "a", "b")
      FileUtils.mkdir_p(sub)
      Dir.chdir(sub) do
        saved = defined?(Bundler) ? Bundler : nil
        Object.send(:remove_const, :Bundler) if saved
        begin
          assert_equal File.join(root, ".rb-apple-sdk-mac"), AppleSDKMac.cache_dir
        ensure
          Object.const_set(:Bundler, saved) if saved
        end
      end
    end
  end

  def test_raises_when_no_gemfile_anywhere
    Dir.mktmpdir do |root|
      Dir.chdir(root) do
        saved = defined?(Bundler) ? Bundler : nil
        Object.send(:remove_const, :Bundler) if saved
        begin
          assert_raise(AppleSDKMac::ProjectRootError) { AppleSDKMac.cache_dir }
        ensure
          Object.const_set(:Bundler, saved) if saved
        end
      end
    end
  end
end
