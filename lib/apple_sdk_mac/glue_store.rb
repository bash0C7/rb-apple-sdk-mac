# frozen_string_literal: true
require "fileutils"
require "json"

module AppleSDKMac
  # Tier 1 committable glue store: .rb-apple-sdk-mac/glue/<sdk-version>/<framework>/<symbol>.swift
  # + <symbol>_round_trip_test.rb (生成時)。
  # content-addressed: symbol ごと独立。commit すれば team/CI が git で受け取り
  # round-trip 再検証して使う（claude -p 不要）。
  class GlueStore
    def initialize(project_dir:, sdk_version:)
      @sdk_version = sdk_version
      @base = File.join(project_dir, "glue", sdk_version)
    end

    def store(framework:, symbol_name:, swift_source:, round_trip_test: nil,
              kind: nil, rule_failure_reason: nil, rule_scaffold: nil, context_used: nil)
      dir = framework_dir(framework.to_s)
      FileUtils.mkdir_p(dir)
      safe = safe_name(symbol_name)
      File.write(File.join(dir, "#{safe}.swift"), swift_source)
      if round_trip_test
        File.write(File.join(dir, "#{safe}_round_trip_test.rb"), round_trip_test)
      end
      # provenance sidecar: store the (pre-escape) framework/symbol/sdk_version
      # plus the金脈 fields spec §5 needs for Tier 3 export, so ExportBundle can
      # reconstruct InferenceRecord without depending on the filename escape.
      if [kind, rule_failure_reason, rule_scaffold, context_used].any? { |v| !v.nil? }
        provenance = {
          "framework" => framework.to_s,
          "symbol" => symbol_name.to_s,
          "sdk_version" => @sdk_version,
          "kind" => kind,
          "rule_failure_reason" => rule_failure_reason,
          "rule_scaffold" => rule_scaffold,
          "context_used" => context_used
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

    # All provenance sidecars under base, each merged with its sibling .swift
    # content under "inferred_glue". String-keyed Hashes; ExportBundle maps them
    # into InferenceRecord. Glues stored without provenance fields contribute no
    # sidecar and are omitted.
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

    # Injective (collision-free) filename encoding. Every non-alphanumeric
    # byte — including `_` itself — is escaped to `_XX` (XX = 2-digit uppercase
    # hex of the byte's ordinal). Because `_` is always an escape marker in the
    # output, distinct symbols never collapse to the same path
    # (e.g. "NSString.foo" → "NSString_2Efoo" vs literal "NSString_foo" →
    # "NSString_5Ffoo"). Alphanumerics pass through unchanged, preserving
    # readability of plain identifiers. ASCII symbol names assumed (Apple SDK
    # symbols are ASCII); the `_%02X` format would widen for >255 ordinals but
    # those do not occur here.
    def safe_name(name) = name.to_s.gsub(/[^A-Za-z0-9]/) { |c| format("_%02X", c.ord) }

    # Inverse of safe_name: decode each `_XX` (XX = 2-digit uppercase hex) back
    # to its byte. Alphanumerics never produce `_XX`, and `_` itself is always
    # encoded as `_5F`, so this decode is unambiguous — it reconstructs the
    # original symbol name exactly. Used by all_entries to surface the original
    # (un-mangled) symbol for user-facing display (e.g. apple:tier1:list).
    def unsafe_name(name) = name.gsub(/_([0-9A-F]{2})/) { $1.to_i(16).chr }

    def swift_path(fw, name) = File.join(framework_dir(fw), "#{safe_name(name)}.swift")
  end
end
