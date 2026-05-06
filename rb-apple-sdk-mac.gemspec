# frozen_string_literal: true

require_relative "lib/apple_sdk_mac/version"

Gem::Specification.new do |spec|
  spec.name = "rb-apple-sdk-mac"
  spec.version = AppleSdkMac::VERSION
  spec.authors = ["bash0C7"]
  spec.email = ["ksb.4038.nullpointer+github@gmail.com"]

  spec.summary = "Runtime dynamic Ruby ↔ Apple SDK bridge for macOS"
  spec.description = <<~DESC
    Call any public Apple framework API from Ruby with no pre-declarations.
    Apple.discover lazily compiles a Swift glue dylib per symbol via the
    9-pillar runtime (Ref Table, Marshal, Callback, ARC, Error, Async,
    Threading, RunLoop, Conformance), backed by an SQLite knowledge cache
    and an LLM-fallback compiler that synthesizes glue for ObjC / Swift
    shapes the deterministic template catalog cannot cover. Returns
    Ruby-native types; out-pointer parameters are auto-allocated; OSStatus
    / NSError surface as Apple::CallError. macOS 26+ / Ruby 4.x master.
  DESC
  spec.homepage = "https://github.com/bash0C7/rb-apple-sdk-mac"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 4.0.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/bash0C7/rb-apple-sdk-mac"

  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ Gemfile .gitignore test/ .github/])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]
  spec.extensions = ["ext/apple_sdk_mac_runtime/extconf.rb"]

  spec.add_dependency "swift_gem"
  spec.add_dependency "rb-foundation-model-mac"
  spec.add_dependency "rb-apple-sdk-knowledge"
  spec.add_dependency "sqlite3", "~> 2.0"
  spec.add_dependency "sqlite-vec", "~> 0.1"
  spec.add_development_dependency "test-unit", "~> 3.6"
end
