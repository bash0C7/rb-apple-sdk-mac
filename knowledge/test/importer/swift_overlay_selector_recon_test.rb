# frozen_string_literal: true
require "test_helper"
require "rb_apple_sdk_knowledge/importer/swift_overlay"

class SwiftOverlaySelectorReconTest < Test::Unit::TestCase
  def setup
    @overlay = AppleSDKKnowledge::Importer::SwiftOverlay.allocate
  end

  # -- objc_selector_for -----------------------------------------------------

  def test_class_func_single_labeled_param
    # Swift: devices(for mediaType:) where label != internal
    # Apple ObjC convention: label "for" maps to "With<Internal>" → devicesWithMediaType:
    decl = {
      kind: :class_func,
      name: "devices",
      params: [{ label: "for", internal: "mediaType", type: "AVMediaType" }]
    }
    assert_equal "devicesWithMediaType:", @overlay.send(:objc_selector_for, "AVCaptureDevice", decl)
  end

  def test_class_func_no_params
    decl = { kind: :class_func, name: "defaultDevice", params: [] }
    assert_equal "defaultDevice", @overlay.send(:objc_selector_for, "AVCaptureDevice", decl)
  end

  def test_instance_func_no_params
    decl = { kind: :instance_func, name: "lockForConfiguration", params: [] }
    assert_equal "lockForConfiguration", @overlay.send(:objc_selector_for, "AVCaptureDevice", decl)
  end

  def test_instance_func_multiple_params
    # When first param label == internal, produces "setFormat<Label>:restLabel:"
    # When second param label != internal, uses the label directly (rest params use label as-is)
    decl = {
      kind: :instance_func,
      name: "setFormat",
      params: [
        { label: "format", internal: "format", type: "AVCaptureDevice.Format" },
        { label: "for", internal: "conn", type: "AVCaptureConnection" }
      ]
    }
    assert_equal "setFormatFormat:for:", @overlay.send(:objc_selector_for, "AVCaptureDevice", decl)
  end

  def test_init_with_single_param
    decl = {
      kind: :init,
      name: "init",
      params: [{ label: "device", internal: "device", type: "AVCaptureDevice" }]
    }
    assert_equal "initWithDevice:", @overlay.send(:objc_selector_for, "AVCaptureInput", decl)
  end

  def test_init_no_params
    decl = { kind: :init, name: "init", params: [] }
    assert_equal "init", @overlay.send(:objc_selector_for, "AVCaptureDevice", decl)
  end

  def test_instance_var_returns_name
    decl = { kind: :instance_var, name: "category", params: [] }
    assert_equal "category", @overlay.send(:objc_selector_for, "AVAudioSession", decl)
  end

  def test_class_var_returns_name
    decl = { kind: :class_var, name: "shared", params: [] }
    assert_equal "shared", @overlay.send(:objc_selector_for, "AVAudioSession", decl)
  end

  # -- swift_imported_name_for -----------------------------------------------

  def test_swift_name_class_func_labeled
    decl = {
      kind: :class_func,
      name: "devices",
      params: [{ label: "for", internal: "mediaType", type: "AVMediaType" }]
    }
    assert_equal "devices(for:)", @overlay.send(:swift_imported_name_for, decl)
  end

  def test_swift_name_class_func_no_params
    decl = { kind: :class_func, name: "defaultDevice", params: [] }
    assert_equal "defaultDevice()", @overlay.send(:swift_imported_name_for, decl)
  end

  def test_swift_name_init_with_params
    decl = {
      kind: :init,
      name: "init",
      params: [{ label: "device", internal: "device", type: "AVCaptureDevice" }]
    }
    assert_equal "init(device:)", @overlay.send(:swift_imported_name_for, decl)
  end

  def test_swift_name_var
    decl = { kind: :instance_var, name: "category", params: [] }
    assert_equal "category", @overlay.send(:swift_imported_name_for, decl)
  end
end
