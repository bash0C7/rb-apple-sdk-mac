# frozen_string_literal: true

require_relative "../lib/apple_sdk_mac/version"

Gem::Specification.new do |spec|
  spec.name = "apple_sdk_mac-irb"
  spec.version = AppleSdkMac::VERSION
  spec.authors = ["bash0C7"]
  spec.email = ["ksb.4038.nullpointer+github@gmail.com"]

  spec.summary = "IRB autocomplete + doc preview + auto-discover prefetch for rb-apple-sdk-mac"
  spec.description = <<~DESC
    Logical sub-gem of rb-apple-sdk-mac providing IRB session enhancements:
    Apple SDK class/method/framework autocompletion via Reline, KB-backed
    doc preview in :show_doc dialog, and silent background pre-discovery on
    popup hover so the first lazy call materializes glue without latency.
    Bound to the parent gem via path: dependency, never published
    independently to rubygems.org.
  DESC
  spec.homepage = "https://github.com/bash0C7/rb-apple-sdk-mac"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 4.0.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/bash0C7/rb-apple-sdk-mac/tree/main/irb"

  spec.files = Dir.chdir(__dir__) do
    Dir.glob(["lib/**/*.rb", "README.md"]).reject { |f| File.directory?(f) }
  end
  spec.require_paths = ["lib"]

  spec.add_dependency "rb-apple-sdk-mac"
  spec.add_dependency "irb", "~> 1.18"
  spec.add_dependency "reline", "~> 0.6"
  spec.add_dependency "repl_type_completor"
  spec.add_dependency "sqlite3", "~> 2.0"

  spec.add_development_dependency "test-unit", "~> 3.6"
  spec.add_development_dependency "rake", "~> 13.0"
end
