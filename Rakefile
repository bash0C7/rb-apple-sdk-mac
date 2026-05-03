# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"
require "fileutils"

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/**/test_*.rb"]
end

task default: :test

namespace :apple do
  namespace :knowledge do
    desc "Rebuild the local SDK knowledge base"
    task :rebuild do
      require "rb_apple_sdk_knowledge"
      sdk_version = AppleSDKKnowledge.detect_sdk_version
      path = AppleSDKKnowledge.knowledge_path(sdk_version: sdk_version)
      FileUtils.mkdir_p(File.dirname(path))
      puts "Building knowledge base at #{path}..."
      AppleSDKKnowledge::Importer.new(store_path: path).run
      puts "Done."
    end

    desc "Print info about the current knowledge base"
    task :info do
      require "rb_apple_sdk_knowledge"
      store = AppleSDKKnowledge.open
      fw = store.db.execute("SELECT COUNT(*) FROM frameworks").flatten.first
      sym = store.db.execute("SELECT COUNT(*) FROM symbols").flatten.first
      puts "Frameworks: #{fw}"
      puts "Symbols:    #{sym}"
      puts "DB path:    #{store.path}"
      store.close
    end
  end
end
