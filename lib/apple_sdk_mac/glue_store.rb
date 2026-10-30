# frozen_string_literal: true
require "fileutils"
require "json"

module AppleSDKMac
  class GlueStore
    def initialize(project_dir:, sdk_version:)
      @sdk_version = sdk_version
      @base = File.join(project_dir, "glue", sdk_version)
    end

    def store(framework:, symbol_name:, swift_source:, round_trip_test: nil,
              kind: nil, rule_failure_reason: nil, rule_scaffold: nil, context_used: nil,
              round_trip_outcome: nil)
      dir = framework_dir(framework.to_s)
      FileUtils.mkdir_p(dir)
      safe = safe_name(symbol_name)
      File.write(File.join(dir, "#{safe}.swift"), swift_source)
      if round_trip_test
        File.write(File.join(dir, "#{safe}_round_trip_test.rb"), round_trip_test)
      end
      if [kind, rule_failure_reason, rule_scaffold, context_used, round_trip_outcome].any? { |v| !v.nil? }
        provenance = {
          "framework" => framework.to_s,
          "symbol" => symbol_name.to_s,
          "sdk_version" => @sdk_version,
          "kind" => kind,
          "rule_failure_reason" => rule_failure_reason,
          "rule_scaffold" => rule_scaffold,
          "context_used" => context_used,
          "round_trip_outcome" => round_trip_outcome
        }
        File.write(File.join(dir, "#{safe}.provenance.json"), JSON.generate(provenance))
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
          symbol_name: unsafe_name(File.basename(parts[1], ".swift")),
          path: path
        }
      end
      entries
    end

    def provenance_entries
      Dir.glob(File.join(@base, "*", "*.provenance.json")).sort.map do |pj|
        data = JSON.parse(File.read(pj))
        swift = pj.sub(/\.provenance\.json\z/, ".swift")
        data["inferred_glue"] = File.exist?(swift) ? File.read(swift) : nil
        data
      end
    end

    private

    def framework_dir(framework) = File.join(@base, framework)

    def safe_name(name) = name.to_s.gsub(/[^A-Za-z0-9]/) { |c| format("_%02X", c.ord) }

    def unsafe_name(name) = name.gsub(/_([0-9A-F]{2})/) { $1.to_i(16).chr }

    def swift_path(fw, name) = File.join(framework_dir(fw), "#{safe_name(name)}.swift")
  end
end
