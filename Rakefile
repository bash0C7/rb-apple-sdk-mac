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
