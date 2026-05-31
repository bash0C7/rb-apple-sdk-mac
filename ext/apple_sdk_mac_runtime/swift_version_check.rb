# frozen_string_literal: true
#
# Vendored from the swift_gem scaffold; do not edit by hand.
# The extension must build without swift_gem on the load path.

require "rubygems"

module SwiftGem
  module SwiftVersionCheck
    MINIMUM = Gem::Version.new("6.3")

    class IncompatibleSwiftVersion < StandardError; end

    module_function

    def call!(prober: method(:default_probe))
      output = prober.call
      version = parse(output)
      if version.nil?
        raise IncompatibleSwiftVersion,
              "swift_gem: cannot parse swift toolchain version from: #{output.inspect}. " \
              "Install Swift #{MINIMUM}+ via swiftly: 'brew install swiftly && swiftly install #{MINIMUM} && swiftly use #{MINIMUM}'."
      end
      if version < MINIMUM
        raise IncompatibleSwiftVersion,
              "swift_gem: requires Swift #{MINIMUM}+ (found #{version}). " \
              "Upgrade via swiftly: 'swiftly install #{MINIMUM} && swiftly use #{MINIMUM}'."
      end
      version
    end

    def parse(output)
      match = output.match(/Apple Swift version (\d+\.\d+(?:\.\d+)?)/)
      match && Gem::Version.new(match[1])
    end

    def default_probe
      `swift --version 2>&1`
    end
  end
end
