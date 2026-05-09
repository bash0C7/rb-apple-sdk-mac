# frozen_string_literal: true
require "test_helper"
require "rb_apple_sdk_knowledge/importer/swift_overlay"

class SwiftOverlayExtensionScanTest < Test::Unit::TestCase
  def setup
    @overlay = AppleSDKKnowledge::Importer::SwiftOverlay.allocate
  end

  MULTI_EXTENSION_SOURCE = <<~SWIFT
    extension AVCaptureDevice {
      @available(macOS 10.7, *)
      open class func devices(for mediaType: AVMediaType) -> [AVCaptureDevice]
    }
    extension AVAudioSession {
      open var category: String { get }
    }
  SWIFT

  NESTED_BRACE_SOURCE = <<~SWIFT
    extension AVCaptureDevice {
      open func lockForConfiguration() throws
      open class func defaultDevice(withDeviceType deviceType: AVCaptureDevice.DeviceType,
                                    mediaType: AVMediaType?,
                                    position: AVCaptureDevice.Position) -> AVCaptureDevice?
    }
  SWIFT

  def test_extracts_single_extension_block
    source = <<~SWIFT
      extension AVCaptureDevice {
        open class func devices(for mediaType: AVMediaType) -> [AVCaptureDevice]
      }
    SWIFT
    blocks = @overlay.send(:extract_extension_blocks, source)
    assert_equal 1, blocks.length
    assert_equal "AVCaptureDevice", blocks[0][:klass]
    assert_match(/devices\(for/, blocks[0][:body])
  end

  def test_extracts_multiple_extension_blocks
    blocks = @overlay.send(:extract_extension_blocks, MULTI_EXTENSION_SOURCE)
    assert_equal 2, blocks.length
    klasses = blocks.map { |b| b[:klass] }
    assert_includes klasses, "AVCaptureDevice"
    assert_includes klasses, "AVAudioSession"
  end

  def test_body_does_not_include_outer_braces
    blocks = @overlay.send(:extract_extension_blocks, MULTI_EXTENSION_SOURCE)
    av = blocks.find { |b| b[:klass] == "AVCaptureDevice" }
    refute_match(/^extension AVCaptureDevice/, av[:body])
    refute_match(/^\}$/, av[:body].strip)
  end

  def test_returns_empty_array_for_no_extensions
    blocks = @overlay.send(:extract_extension_blocks, "public class Foo {}\n")
    assert_equal [], blocks
  end

  def test_handles_multiline_body
    blocks = @overlay.send(:extract_extension_blocks, NESTED_BRACE_SOURCE)
    assert_equal 1, blocks.length
    assert_equal "AVCaptureDevice", blocks[0][:klass]
    assert_match(/lockForConfiguration/, blocks[0][:body])
    assert_match(/defaultDevice/, blocks[0][:body])
  end
end
