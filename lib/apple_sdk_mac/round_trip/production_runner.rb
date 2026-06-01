# lib/apple_sdk_mac/round_trip/production_runner.rb
# frozen_string_literal: true
require "open3"
require "tmpdir"
require_relative "harness"
require_relative "driver_generator"
require_relative "../glue_loader"

module AppleSDKMac
  module RoundTrip
    # production の round-trip 配線。GlueCompiler#try_inference が swiftc 成功直後に
    # 注入して呼ぶ。直走側は driver_inputs の call_expr から Swift driver を生成して
    # executable コンパイル+実走、wrapper 側は既にコンパイル済みの glue dylib を
    # GlueLoader で load+invoke し、Harness で突合する。
    #
    # value_kind 別の wrapper 値:
    #   :value  → invoke 戻り値そのまま (Equivalence が swift["v"] と値比較)
    #   :opaque → {"type"=>クラス名, "null"=>nil判定} 形に整形
    #   :setter → invoke 戻りを {"set","readback"} 形でそのまま渡す
    #
    # swift_exec / loader は inject 可能 (unit は実 swiftc/dylib なしで wiring 検証)。
    # 実 swiftc を使う :value の end-to-end は gate-ON e2e で実証する。
    class ProductionRunner
      def initialize(swift_exec: nil, loader: nil, sdk_path: nil, target: "arm64-apple-macos26.0",
                     swiftc: nil)
        @swift_exec = swift_exec
        @loader = loader || GlueLoader.new
        @sdk_path = sdk_path
        @target = target
        @swiftc = swiftc || ENV["RB_APPLE_SDK_MAC_SWIFTC"] || "swiftc"
      end

      # @return [Harness::Outcome]
      def run(framework:, symbol:, dylib:, exported:)
        value_kind = symbol[:value_kind].to_sym
        harness = Harness.new(
          swift_runner: @swift_exec || method(:compile_and_run_driver),
          ruby_runner: -> { ruby_value(symbol, dylib, exported, value_kind) }
        )
        harness.check(framework: framework, symbol: symbol, value_kind: value_kind)
      end

      private

      def ruby_value(symbol, dylib, exported, value_kind)
        fn_ptr = @loader.load(dylib_path: dylib, exported_symbol: exported)
        raw = @loader.invoke(fn_ptr, Array(symbol[:invoke_args]))
        case value_kind
        when :value  then raw
        when :opaque then { "type" => raw.class.name, "null" => raw.nil? }
        when :setter then raw
        else raise ArgumentError, "unknown value_kind: #{value_kind.inspect}"
        end
      end

      # call_expr 入り Swift driver を EXECUTABLE としてコンパイル (-emit-library は
      # top-level code を捨てるので使わない) し実走、stdout を返す。
      def compile_and_run_driver(swift_source)
        Dir.mktmpdir("rt_prod_driver") do |dir|
          src = File.join(dir, "driver.swift")
          bin = File.join(dir, "driver")
          File.write(src, swift_source)
          args = ["-target", @target]
          args += ["-sdk", sdk_path] if sdk_path
          args += ["-o", bin, src]
          out, err, status = Open3.capture3(@swiftc, *args)
          # compile 失敗は RTRESULT 無し → Harness が RED 縮退。raw stderr を detail へ。
          return "swift driver compile failed: #{err}" unless status.success?
          run_out, _run_err, _run_status = Open3.capture3(bin)
          run_out
        end
      end

      def sdk_path
        @sdk_path ||= begin
          require "rb_apple_sdk_knowledge"
          AppleSDKKnowledge::SDK.path
        rescue LoadError
          nil
        end
      end
    end
  end
end
