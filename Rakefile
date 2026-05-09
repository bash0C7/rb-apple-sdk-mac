# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"
require "rake/extensiontask"

Rake::ExtensionTask.new("apple_sdk_mac_runtime") do |ext|
  ext.lib_dir = "lib/apple_sdk_mac"
end

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.libs << "tooling/lib"
  t.test_files = FileList["test/**/*_test.rb", "knowledge/test/test_*.rb"]
end

namespace :runtime do
  desc "Regenerate CallbackPillarGenerated.swift from callback_signatures.yml"
  task :codegen_callback_pillar do
    $LOAD_PATH.unshift File.expand_path("lib", __dir__)
    require "apple_sdk_mac/callback_pillar_codegen"
    yaml = "ext/apple_sdk_mac_runtime/callback_signatures.yml"
    out  = "ext/apple_sdk_mac_runtime/Sources/AppleSDKMacRuntime/CallbackPillarGenerated.swift"
    File.write(out, AppleSDKMac::CallbackPillarCodegen.generate(yaml))
    puts "wrote #{out}"
  end
end

namespace :apple do
  namespace :knowledge do
    desc "Rebuild KB SQLite into <project>/.rb-apple-sdk-mac/knowledge/ (project-scoped)"
    task :rebuild do
      require "fileutils"
      require_relative "lib/apple_sdk_mac/cache_dir"
      kb_base = File.join(AppleSDKMac.cache_dir, "knowledge")
      FileUtils.mkdir_p(kb_base)
      Dir.chdir(File.expand_path("knowledge", __dir__)) do
        sh({ "APPLE_SDK_MAC_KB_BASE_DIR" => kb_base }, "bundle", "exec", "rake", "apple:knowledge:rebuild")
      end
    end

    desc "Detached rebuild via screen (CLAUDE.md ロングバッチ pattern; tail tmp/longrun/<NAME>.log)"
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
      puts "status:  grep '^DONE:' #{log}   (0 lines = running, 1 line = finished w/ exit code)"
      puts "kill:    screen -X -S #{name} quit"
    end
  end

  namespace :runtime do
    desc "swift build the runtime dylib (release config) and copy generated -Swift.h into ext/"
    task :sync_header do
      ext_dir = File.expand_path("ext/apple_sdk_mac_runtime", __dir__)
      # The C extension is linked with @rpath=.build/release, so the runtime
      # Swift dylib MUST be built in release config or new exports will go
      # missing at dlopen. (debug config is built incidentally by swift_gem
      # tooling; we build release ourselves here.)
      sh "swift", "build", "-c", "release", "--package-path", ext_dir
      # 明示的に release configuration の生成 header を選ぶ。Dir.glob の
      # alphabetical 順だと debug header (incidentally 生成されたもの) が先に
      # 取れ、 release config で追加した新 export の宣言を含まない header が
      # ext/ にコピーされてしまう (= rake compile の C ext が新 export を
      # 解決できない)。
      release_glob = File.join(ext_dir, ".build", "**", "release", "**", "AppleSDKMacRuntime-Swift.h")
      generated = Dir.glob(release_glob).first
      generated ||= Dir.glob(File.join(ext_dir, ".build", "**", "AppleSDKMacRuntime-Swift.h")).first
      raise "AppleSDKMacRuntime-Swift.h not produced by swift build" unless generated
      target = File.join(ext_dir, "AppleSDKMacRuntime-Swift.h")
      require "fileutils"
      FileUtils.cp(generated, target)
      puts "synced #{generated} -> #{target}"
    end
  end

  namespace :cache do
    # Cache directory layout: ~/.cache/rb-apple-sdk-mac/<sdk_version>/{lib,sources}
    # + compiled_glue.sqlite (compiled_glue_cache.rb で管理)。
    # CACHE_SCHEMA_VERSION bump 時 / dylib export 名変更時に lib/sources を
    # 一括 invalidate するための明示 task。 直接 `rm -rf` するのは禁止 (user
    # feedback 2026-05-07): scope を必ず Rakefile task で固定する。
    CACHE_ROOT = File.expand_path("~/.cache/rb-apple-sdk-mac")

    def _safe_inside_cache_root?(path)
      abs = File.expand_path(path)
      abs.start_with?(CACHE_ROOT + File::SEPARATOR) || abs == CACHE_ROOT
    end

    desc "Clear compiled glue dylibs + Swift sources for the given SDK version (default: env SDK_VERSION or 26.2)"
    task :clear_glue do
      require "fileutils"
      sdk_version = ENV["SDK_VERSION"] || "26.2"
      raise "invalid SDK_VERSION '#{sdk_version}'" unless sdk_version =~ /\A[0-9.]+\z/
      base = File.join(CACHE_ROOT, sdk_version)
      raise "cache base outside CACHE_ROOT: #{base}" unless _safe_inside_cache_root?(base)
      unless File.directory?(base)
        puts "no cache to clear at #{base}"
        next
      end
      ["lib", "sources"].each do |sub|
        dir = File.join(base, sub)
        next unless File.directory?(dir) && _safe_inside_cache_root?(dir)
        Dir.glob(File.join(dir, "*")).each do |entry|
          next unless _safe_inside_cache_root?(entry)
          FileUtils.rm_rf(entry)
        end
        puts "cleared #{dir}"
      end
    end

    desc "Clear the glue.sqlite DB for the given SDK version (default: env SDK_VERSION or 26.2)"
    task :clear_db do
      require "fileutils"
      sdk_version = ENV["SDK_VERSION"] || "26.2"
      raise "invalid SDK_VERSION '#{sdk_version}'" unless sdk_version =~ /\A[0-9.]+\z/
      base = File.join(CACHE_ROOT, sdk_version)
      raise "cache base outside CACHE_ROOT: #{base}" unless _safe_inside_cache_root?(base)
      # CompiledGlueCache が実際に使う DB は `glue.sqlite` (compiled_glue_cache.rb
      # L86)。 古い名前 (compiled_glue.sqlite) も並行して残っていれば一緒に削除。
      patterns = ["glue*.sqlite*", "compiled_glue*.sqlite*"]
      patterns.each do |pat|
        Dir.glob(File.join(base, pat)).each do |entry|
          next unless _safe_inside_cache_root?(entry)
          FileUtils.rm_f(entry)
          puts "cleared #{entry}"
        end
      end
    end

    desc "Clear all cache artifacts (glue + sources + DB) for the given SDK version"
    task :clear_all => [:clear_glue, :clear_db]

    desc "Remove project-scoped glue artifacts (<project>/.rb-apple-sdk-mac)"
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

task compile: ["runtime:codegen_callback_pillar", "apple:runtime:sync_header"]

desc "Start an IRB console with apple_sdk_mac loaded"
task console: :compile do
  require "irb"
  $LOAD_PATH.unshift File.expand_path("lib", __dir__)
  require "apple_sdk_mac"
  ARGV.clear
  IRB.start
end

task test: :compile

# Phase 7 / v1.0 — release-quality aggregate. Runs the spec §9
# acceptance suite plus the benchmark in one command. Individual
# subtasks include env-gated heavy ones; a full v1.0 ship run on
# macOS 26 hardware should report PASS for everything below.
namespace :test do
  desc "Run the spec §9 release-quality suite (test + canonical + examples + coverage + leak + concurrent + bench)"
  task release_quality: :test do
    [
      "test/integration/readme_canonical_test.rb",
      "test/integration/examples_smoke_test.rb",
      "test/integration/discover_coverage_test.rb",
      "test/integration/memory_leak_test.rb",
      "test/concurrency/concurrent_discover_test.rb"
    ].each do |t|
      sh "bundle", "exec", "ruby", "-Ilib", "-Itest", t
    end
    # Default budget here is loose (1000µs) so a normal CI box passes.
    # Override via BENCH_BUDGET_US=200 for the strict spec §9 target.
    sh({ "RUBY_BOX" => "1", "BENCH_BUDGET_US" => ENV["BENCH_BUDGET_US"] || "1000" },
       "bundle", "exec", "ruby", "benchmark/dispatch_overhead.rb")
  end
end

task default: :test

load "tooling/lib/tasks/emitter.rake"
