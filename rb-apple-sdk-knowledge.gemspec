# frozen_string_literal: true

require_relative "lib/rb_apple_sdk_knowledge/version"

Gem::Specification.new do |spec|
  spec.name = "rb-apple-sdk-knowledge"
  spec.version = AppleSDKKnowledge::VERSION
  spec.authors = ["bash0C7"]
  spec.email = ["ksb.4038.nullpointer+github@gmail.com"]

  spec.summary = "SQLite knowledge base of the local Xcode SDK Apple framework symbols, used by rb-apple-sdk-mac"
  spec.description = "Builds a SQLite knowledge base of every public Apple framework on the local Xcode SDK at install time. Independently usable for IDE completion, lint, and RBS generation."
  spec.homepage = "https://github.com/bash0C7/rb-apple-sdk-knowledge"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ Gemfile .gitignore test/ .github/ .rubocop.yml])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "sqlite3", "~> 2.0"
  spec.add_dependency "sqlite-vec", "~> 0.1"
  spec.add_development_dependency "test-unit", "~> 3.6"
  spec.add_development_dependency "rake", "~> 13.0"
end
