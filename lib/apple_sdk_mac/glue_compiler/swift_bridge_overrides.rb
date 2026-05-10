# frozen_string_literal: true

module AppleSDKMac
  class GlueCompiler
    # Manual overrides for ObjC selector → Swift bridge call expression.
    #
    # When the Swift overlay importer (Phase 4a) and the heuristic both miss
    # (typically because Apple's Swift overlay defined a custom name not
    # derivable from the selector), drop the (framework, klass, selector) →
    # canonical "method(label1: arg0, label2: arg1)" form here. The lookup
    # is keyed by [framework, klass, selector] string triplet.
    #
    # Format: hash entry value is a `%`-format string with positional `%s`
    # tokens for `arg0`, `arg1`, ... — the SwiftBridgeName module fills them.
    # Example:
    #   ["AVFoundation", "AVCaptureDevice", "devicesWithMediaType:"] =>
    #     "AVCaptureDevice.devices(for: %s)"
    SWIFT_BRIDGE_OVERRIDES = {}.freeze
  end
end
