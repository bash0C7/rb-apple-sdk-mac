# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"
require "rake/extensiontask"

namespace :runtime do
  desc "Regenerate CallbackPillarGenerated.swift from callback_signatures.yml"
  task :codegen_callback_pillar do
    require_relative "lib/apple_sdk_mac/callback_pillar_codegen"
    yaml = "ext/apple_sdk_mac_runtime/callback_signatures.yml"
    out  = "ext/apple_sdk_mac_runtime/Sources/AppleSDKMacRuntime/CallbackPillarGenerated.swift"
    File.write(out, AppleSDKMac::CallbackPillarCodegen.generate(yaml))
    puts "wrote #{out}"
  end
end

desc "Build the Swift package"
task swift: "runtime:codegen_callback_pillar" do
  sh "xcrun", "swift", "build", "-c", "release", "--package-path", "ext/apple_sdk_mac_runtime"
end

task compile: :swift

Rake::ExtensionTask.new("apple_sdk_mac_runtime") do |ext|
  ext.lib_dir = "lib/apple_sdk_mac"
end

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.libs << "tooling/lib"
  t.test_files = FileList["test/**/*_test.rb", "test/**/test_*.rb", "knowledge/test/test_*.rb"] -
                 FileList["test/integration/**/*", "test/test_helper.rb", "knowledge/test/test_helper.rb"]
end

desc "Validate the RBS signatures"
task :rbs do
  sh "rbs", "-I", "sig", "validate"
end

namespace :apple do
  namespace :knowledge do
    desc "Rebuild the Knowledge Base SQLite into <project>/.rb-apple-sdk-mac/knowledge/"
    task :rebuild do
      require "fileutils"
      require_relative "lib/apple_sdk_mac/cache_dir"
      kb_base = File.join(AppleSDKMac.cache_dir, "knowledge")
      FileUtils.mkdir_p(kb_base)
      Dir.chdir(File.expand_path("knowledge", __dir__)) do
        sh({ "APPLE_SDK_MAC_KB_BASE_DIR" => kb_base }, "bundle", "exec", "rake", "apple:knowledge:rebuild")
      end
    end

    desc "Remove the Knowledge Base SQLite under <project>/.rb-apple-sdk-mac/knowledge/"
    task :clean do
      require "fileutils"
      require_relative "lib/apple_sdk_mac/cache_dir"
      kb_base = File.join(AppleSDKMac.cache_dir, "knowledge")
      if File.directory?(kb_base)
        FileUtils.rm_rf(kb_base)
        puts "cleaned: #{kb_base}"
      else
        puts "nothing to clean: #{kb_base} does not exist"
      end
    end

    desc "Rebuild the Knowledge Base in a detached screen session (log: tmp/longrun/<NAME>.log)"
    task :rebuild_async do
      require "fileutils"
      FileUtils.mkdir_p("tmp/longrun")
      name = ENV.fetch("NAME", "knowledge-rebuild-#{Time.now.strftime('%Y%m%d-%H%M%S')}")
      log  = File.join("tmp/longrun", "#{name}.log")
      cmd  = <<~SH
        bundle exec rake apple:knowledge:rebuild > #{log} 2>&1
        echo "DONE: exit=$?" >> #{log}
      SH
      ok = system("screen", "-dmS", name, "bash", "-c", cmd)
      raise "screen -dmS failed for #{name}" unless ok
      puts "started detached rebuild: screen session=#{name} log=#{log}"
      puts "tail:    tail -f #{log}"
      puts "status:  grep '^DONE:' #{log}"
      puts "kill:    screen -X -S #{name} quit"
    end
  end

  namespace :tier1 do
    desc "List the stored Tier 1 glues for the active SDK"
    task :list do
      require "rb_apple_sdk_knowledge"
      require_relative "lib/apple_sdk_mac/cache_dir"
      require_relative "lib/apple_sdk_mac/glue_store"
      store = AppleSDKMac::GlueStore.new(project_dir: AppleSDKMac.cache_dir, sdk_version: AppleSDKKnowledge::SDK.version)
      entries = store.all_entries
      if entries.empty?
        puts "No Tier 1 glues stored yet."
      else
        entries.each { |e| puts "#{e[:framework]}/#{e[:symbol_name]}" }
        puts "Total: #{entries.size}"
      end
    end

    desc "Clear the Tier 1 glue store for the active SDK"
    task :clear do
      require "fileutils"
      require "rb_apple_sdk_knowledge"
      require_relative "lib/apple_sdk_mac/cache_dir"
      target = File.join(AppleSDKMac.cache_dir, "glue", AppleSDKKnowledge::SDK.version)
      if Dir.exist?(target)
        FileUtils.rm_rf(target)
        puts "Cleared Tier 1 store: #{target}"
      else
        puts "Nothing to clear: #{target}"
      end
    end
  end

  namespace :tier3 do
    desc "Export inference bundle to JSON (output: tmp/tier3_export.json)"
    task :export do
      require "fileutils"
      require "rb_apple_sdk_knowledge"
      require_relative "lib/apple_sdk_mac/cache_dir"
      require_relative "lib/apple_sdk_mac/glue_store"
      require_relative "lib/apple_sdk_mac/export_bundle"
      store = AppleSDKMac::GlueStore.new(project_dir: AppleSDKMac.cache_dir, sdk_version: AppleSDKKnowledge::SDK.version)
      records = AppleSDKMac::ExportBundle.from_glue_store(store)
      if records.empty?
        puts "No inference-provenance glues stored; nothing to export."
        next
      end
      summary = AppleSDKMac::ExportBundle.cluster_summary(records)
      puts "Failure reason clusters:"
      summary.each { |k, v| puts "  #{k}: #{v}" }
      FileUtils.mkdir_p("tmp")
      out = "tmp/tier3_export.json"
      File.write(out, AppleSDKMac::ExportBundle.to_json(records))
      puts "Exported #{records.size} inference records -> #{out}"
    end
  end

  namespace :cache do
    def cache_sdk_dir
      require "rb_apple_sdk_knowledge"
      require_relative "lib/apple_sdk_mac/cache_dir"
      sdk_version = ENV.fetch("SDK_VERSION") { AppleSDKKnowledge::SDK.version }
      raise "invalid SDK_VERSION '#{sdk_version}'" unless sdk_version.match?(/\A[0-9.]+\z/)
      File.join(AppleSDKMac.cache_dir, sdk_version)
    end

    desc "Clear compiled glue dylibs and Swift sources for SDK_VERSION (default: the active SDK)"
    task :clear_glue do
      require "fileutils"
      base = cache_sdk_dir
      %w[lib sources].each do |sub|
        dir = File.join(base, sub)
        next unless File.directory?(dir)
        FileUtils.rm_rf(Dir.glob(File.join(dir, "*")))
        puts "cleared #{dir}"
      end
    end

    desc "Clear the glue.sqlite DB for SDK_VERSION (default: the active SDK)"
    task :clear_db do
      require "fileutils"
      Dir.glob(File.join(cache_sdk_dir, "glue*.sqlite*")).each do |entry|
        FileUtils.rm_f(entry)
        puts "cleared #{entry}"
      end
    end

    desc "Clear compiled glue, Swift sources, and the glue DB for SDK_VERSION"
    task clear_all: %i[clear_glue clear_db]

    desc "Remove all project-scoped artifacts (<project>/.rb-apple-sdk-mac)"
    task :clear do
      require "fileutils"
      require_relative "lib/apple_sdk_mac/cache_dir"
      target = AppleSDKMac.cache_dir
      if Dir.exist?(target)
        FileUtils.rm_rf(target)
        puts "Cleared: #{target}"
      else
        puts "Nothing to clear: #{target}"
      end
    end
  end
end

desc "Start an IRB console with apple_sdk_mac loaded"
task console: :compile do
  require "irb"
  $LOAD_PATH.unshift File.expand_path("lib", __dir__)
  require "apple_sdk_mac"
  ARGV.clear
  IRB.start
end

task test: %i[rbs compile]

namespace :test do
  desc "Run the release-quality suite (test + canonical + examples + coverage + leak + concurrent + bench)"
  task release_quality: :test do
    [
      "test/integration/readme_canonical_test.rb",
      "test/integration/examples_smoke_test.rb",
      "test/integration/full_rebuild_assertions_test.rb",
      "test/integration/discover_coverage_test.rb",
      "test/integration/memory_leak_test.rb",
      "test/integration/concurrent_discover_test.rb"
    ].each do |t|
      sh "bundle", "exec", "ruby", "-Ilib", "-Itest", t
    end
    sh({ "RUBY_BOX" => "1", "BENCH_BUDGET_US" => ENV["BENCH_BUDGET_US"] || "1000" },
       "bundle", "exec", "ruby", "benchmark/dispatch_overhead.rb")
  end
end

task default: :test

load "tooling/lib/tasks/emitter.rake"
