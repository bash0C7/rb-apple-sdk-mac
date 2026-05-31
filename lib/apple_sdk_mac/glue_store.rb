# frozen_string_literal: true
require "fileutils"

module AppleSDKMac
  # Tier 1 committable glue store: .rb-apple-sdk-mac/glue/<sdk-version>/<framework>/<symbol>.swift
  # + <symbol>_round_trip_test.rb (生成時)。
  # content-addressed: symbol ごと独立。commit すれば team/CI が git で受け取り
  # round-trip 再検証して使う（claude -p 不要）。
  class GlueStore
    def initialize(project_dir:, sdk_version:)
      @base = File.join(project_dir, "glue", sdk_version)
    end

    def store(framework:, symbol_name:, swift_source:, round_trip_test: nil)
      dir = framework_dir(framework.to_s)
      FileUtils.mkdir_p(dir)
      safe = safe_name(symbol_name)
      File.write(File.join(dir, "#{safe}.swift"), swift_source)
      if round_trip_test
        File.write(File.join(dir, "#{safe}_round_trip_test.rb"), round_trip_test)
      end
    end

    def lookup(framework:, symbol_name:)
      path = swift_path(framework.to_s, symbol_name)
      File.exist?(path) ? File.read(path) : nil
    end

    def round_trip_test_path(framework:, symbol_name:)
      safe = safe_name(symbol_name)
      File.join(framework_dir(framework.to_s), "#{safe}_round_trip_test.rb")
    end

    def all_entries
      entries = []
      Dir.glob(File.join(@base, "*", "*.swift")).each do |path|
        rel = path.sub(File.join(@base, ""), "")
        parts = rel.split(File::SEPARATOR)
        next unless parts.size == 2
        entries << {
          framework: parts[0],
          symbol_name: File.basename(parts[1], ".swift"),
          path: path
        }
      end
      entries
    end

    private

    def framework_dir(framework) = File.join(@base, framework)
    def safe_name(name) = name.to_s.gsub(/[^A-Za-z0-9_]/, "_")
    def swift_path(fw, name) = File.join(framework_dir(fw), "#{safe_name(name)}.swift")
  end
end
