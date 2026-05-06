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
  t.test_files = FileList["test/**/*_test.rb"]
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
  namespace :runtime do
    desc "swift build the runtime dylib (release config) and copy generated -Swift.h into ext/"
    task :sync_header do
      ext_dir = File.expand_path("ext/apple_sdk_mac_runtime", __dir__)
      # The C extension is linked with @rpath=.build/release, so the runtime
      # Swift dylib MUST be built in release config or new exports will go
      # missing at dlopen. (debug config is built incidentally by swift_gem
      # tooling; we build release ourselves here.)
      sh "swift", "build", "-c", "release", "--package-path", ext_dir
      generated = Dir.glob(File.join(ext_dir, ".build", "**", "AppleSDKMacRuntime-Swift.h")).first
      raise "AppleSDKMacRuntime-Swift.h not produced by swift build" unless generated
      target = File.join(ext_dir, "AppleSDKMacRuntime-Swift.h")
      require "fileutils"
      FileUtils.cp(generated, target)
      puts "synced #{generated} -> #{target}"
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
task default: :test
