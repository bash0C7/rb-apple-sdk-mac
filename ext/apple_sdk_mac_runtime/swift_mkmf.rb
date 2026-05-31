# frozen_string_literal: true
#
# Vendored from the swift_gem scaffold; do not edit by hand.
# The extension must build without swift_gem on the load path.

require "mkmf"
require_relative "swift_version_check"

module SwiftGem
  module Mkmf
    extend ::MakeMakefile

    DEFAULT_BUILDER = lambda do |package, source_dir|
      header_path = File.join(File.expand_path(source_dir), "#{package}-Swift.h")
      ok = system(
        "swift", "build", "-c", "release", "--package-path", source_dir,
        "-Xswiftc", "-emit-clang-header-path", "-Xswiftc", header_path
      )
      raise "swift build failed for package #{package.inspect}" unless ok
      File.expand_path(".build/release", source_dir)
    end

    def self.create_swift_makefile(target, package:, source_dir:, builder: DEFAULT_BUILDER,
                                   swift_version_probe: SwiftVersionCheck.method(:default_probe))
      SwiftVersionCheck.call!(prober: swift_version_probe)
      lib_dir = builder.call(package, source_dir)
      $CFLAGS  << " -I#{File.expand_path(source_dir)}"
      $LDFLAGS << " -Wl,-rpath,#{lib_dir} -L#{lib_dir} -l#{package}"
      create_makefile(target)
    end
  end
end
