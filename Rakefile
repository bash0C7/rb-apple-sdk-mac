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
  # test/integration/ holds end-to-end suites (real-SDK assertions, examples
  # smoke, memory leak, concurrency). Those are run explicitly by
  # `rake test:release_quality` below; excluding them from the default glob
  # keeps `rake test` under a few minutes for the inner-loop dev cycle.
  t.test_files = FileList["test/**/*_test.rb", "knowledge/test/test_*.rb"] -
                 FileList["test/integration/**/*"]
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

    desc "Wipe project-scoped Knowledge Base SQLite under .rb-apple-sdk-mac/knowledge/ (scoped — does not touch ~/.cache)"
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

  namespace :tier1 do
    desc "List all Tier 1 stored glues in .rb-apple-sdk-mac/glue/"
    task :list do
      require_relative "lib/apple_sdk_mac/cache_dir"
      require_relative "lib/apple_sdk_mac/glue_store"
      begin
        sdk_ver = begin
          require "rb_apple_sdk_knowledge"
          AppleSDKKnowledge::SDK.version
        rescue LoadError
          ENV["SDK_VERSION"] || "26.5"
        end
        store = AppleSDKMac::GlueStore.new(project_dir: AppleSDKMac.cache_dir, sdk_version: sdk_ver)
        entries = store.all_entries
        if entries.empty?
          puts "No Tier 1 glues stored yet."
        else
          entries.each { |e| puts "#{e[:framework]}/#{e[:symbol_name]}" }
          puts "Total: #{entries.size}"
        end
      rescue AppleSDKMac::ProjectRootError => e
        puts "#{e.message}"
      end
    end

    desc "Clear Tier 1 glue store for the resolved SDK version " \
         "(rb_apple_sdk_knowledge if available, else env SDK_VERSION or 26.5; same resolution as tier1:list)"
    task :clear do
      require "fileutils"
      require_relative "lib/apple_sdk_mac/cache_dir"
      # Resolve sdk_ver the same way tier1:list does so "what list shows is what
      # clear removes". A library-provided version is trusted; only the ENV
      # fallback (attacker-controllable) gets the regex guard below.
      sdk_ver = begin
        require "rb_apple_sdk_knowledge"
        AppleSDKKnowledge::SDK.version
      rescue LoadError
        env = ENV["SDK_VERSION"] || "26.5"
        # Guard against path traversal (e.g. SDK_VERSION="../../etc") before
        # this value flows into File.join → rm_rf. Mirrors cache:clear_glue.
        unless env =~ /\A[0-9.]+\z/
          abort "invalid SDK_VERSION '#{env}' (expected digits and dots only)"
        end
        env
      end
      glue_root = File.join(AppleSDKMac.cache_dir, "glue")
      target = File.join(glue_root, sdk_ver)
      # Containment guard: refuse to rm_rf anything outside the Tier 1 glue root,
      # even if the resolved version somehow escaped (defense in depth).
      abs_target = File.expand_path(target)
      abs_root = File.expand_path(glue_root)
      unless abs_target.start_with?(abs_root + File::SEPARATOR)
        abort "refusing to clear: #{abs_target} is outside the glue root #{abs_root}"
      end
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
      require_relative "lib/apple_sdk_mac/cache_dir"
      require_relative "lib/apple_sdk_mac/compiled_glue_cache"
      require_relative "lib/apple_sdk_mac/export_bundle"
      begin
        require "rb_apple_sdk_knowledge"
        sdk_ver = AppleSDKKnowledge::SDK.version
      rescue LoadError
        sdk_ver = ENV["SDK_VERSION"] || "26.5"
      end
      cache_path = AppleSDKMac.cache_dir
      db_path = File.join(cache_path, sdk_ver)
      unless Dir.exist?(db_path)
        puts "No glue cache at #{db_path}; nothing to export."
        next
      end
      cache = AppleSDKMac::CompiledGlueCache.open(cache_path, sdk_version: sdk_ver)
      records = AppleSDKMac::ExportBundle.from_cache(cache)
      cache.close
      if records.empty?
        puts "No inference-generated glues in cache; nothing to export."
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
      # CompiledGlueCache が実際に使う DB は `glue.sqlite` (compiled_glue_cache.rb L86)。
      patterns = ["glue*.sqlite*"]
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

# Release-quality aggregate. Runs the acceptance suite plus the benchmark
# in one command. Individual subtasks include env-gated heavy ones; a full
# ship run on macOS 26 hardware should report PASS for everything below.
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
    # Default budget here is loose (1000µs) so a normal CI box passes.
    # Override via BENCH_BUDGET_US=200 for the strict release-quality target.
    sh({ "RUBY_BOX" => "1", "BENCH_BUDGET_US" => ENV["BENCH_BUDGET_US"] || "1000" },
       "bundle", "exec", "ruby", "benchmark/dispatch_overhead.rb")
  end
end

task default: :test

load "tooling/lib/tasks/emitter.rake"
