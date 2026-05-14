# frozen_string_literal: true
require "ruby-progressbar"

module AppleSDKKnowledge
  module Importer
    class ProgressReporter
      ANSI_RESET = "\e[0m"

      def initialize(io: $stderr, total_frameworks:, tty: io.tty?)
        @io = io
        @total = total_frameworks
        @tty = tty
        if @tty
          @io.print ANSI_RESET
          @bar = ProgressBar.create(
            output: io,
            total: total_frameworks,
            format: "%t [%B] %c/%C %e"
          )
        end
      end

      def framework_started(name, idx:, total:)
        if @tty
          @bar.title = name
        else
          @io.puts "=== #{name} (#{idx + 1}/#{total}) ==="
        end
      end

      def header_done(framework:, header:, status:, elapsed_ms:, error: nil)
        return if @tty
        return unless status == :error
        first = error.to_s.lines.first.to_s.strip
        @io.puts "[importer] skipping #{header}: #{first}"
      end

      def framework_finished(name, processed:, skipped:, elapsed_ms:)
        if @tty
          @bar.increment
        else
          @io.puts "→ processed=#{processed} skipped=#{skipped} elapsed=#{format_elapsed(elapsed_ms)}"
        end
      end

      def finish(processed_total:, skipped_total:, elapsed_ms:)
        msg = "✓ done processed=#{processed_total} skipped=#{skipped_total} elapsed=#{format_elapsed(elapsed_ms)}"
        @bar.finish if @tty
        @io.puts msg
      end

      private

      def format_elapsed(ms)
        s = ms / 1000.0
        return "#{s.round(1)}s" if s < 60
        m = (s / 60).to_i
        rem = (s - m * 60).round
        "#{m}m#{rem}s"
      end
    end
  end
end
