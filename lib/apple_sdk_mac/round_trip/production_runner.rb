# frozen_string_literal: true
require "open3"
require "tmpdir"
require "rb_apple_sdk_knowledge"
require_relative "harness"
require_relative "driver_generator"
require_relative "../glue_loader"

module AppleSDKMac
  module RoundTrip
    class ProductionRunner
      def initialize(swift_exec: nil, loader: nil, sdk_path: nil, target: "arm64-apple-macos27.0",
                     swiftc: nil)
        @swift_exec = swift_exec
        @loader = loader || GlueLoader.new
        @sdk_path = sdk_path
        @target = target
        @swiftc = swiftc ? [swiftc] : %w[xcrun swiftc]
      end

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

      def compile_and_run_driver(swift_source)
        Dir.mktmpdir("rt_prod_driver") do |dir|
          src = File.join(dir, "driver.swift")
          bin = File.join(dir, "driver")
          File.write(src, swift_source)
          args = ["-target", @target, "-sdk", sdk_path, "-o", bin, src]
          out, err, status = Open3.capture3(*@swiftc, *args)
          return "swift driver compile failed: #{err}" unless status.success?
          run_out, _run_err, _run_status = Open3.capture3(bin)
          run_out
        end
      end

      def sdk_path
        @sdk_path ||= AppleSDKKnowledge::SDK.path
      end
    end
  end
end
