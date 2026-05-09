# frozen_string_literal: true
module AppleSDKMac
  class ProjectRootError < StandardError; end

  def self.cache_dir
    root = bundler_root || gemfile_walk_up
    raise ProjectRootError, "rb-apple-sdk-mac: project root を特定できません。 Gemfile / gems.rb のあるディレクトリで実行してください。" unless root
    File.join(root, ".rb-apple-sdk-mac")
  end

  class << self
    private

    def bundler_root
      return nil unless defined?(Bundler) && Bundler.respond_to?(:root)
      Bundler.root.to_s
    rescue StandardError
      nil
    end

    def gemfile_walk_up
      dir = Dir.pwd
      while dir != "/"
        return dir if File.exist?(File.join(dir, "Gemfile")) || File.exist?(File.join(dir, "gems.rb"))
        dir = File.dirname(dir)
      end
      nil
    end
  end
end
