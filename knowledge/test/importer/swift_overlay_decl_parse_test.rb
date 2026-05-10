# frozen_string_literal: true
require "test_helper"
require "rb_apple_sdk_knowledge/importer/swift_overlay"

class SwiftOverlayDeclParseTest < Test::Unit::TestCase
  def setup
    @overlay = AppleSDKKnowledge::Importer::SwiftOverlay.allocate
  end

  # -- parse_decl_line -------------------------------------------------------

  def test_parses_class_func_with_params
    line = "open class func devices(for mediaType: AVMediaType) -> [AVCaptureDevice]"
    decl = @overlay.send(:parse_decl_line, line)
    refute_nil decl
    assert_equal :class_func, decl[:kind]
    assert_equal "devices", decl[:name]
    assert_equal 1, decl[:params].length
    assert_equal "for", decl[:params][0][:label]
    assert_equal "mediaType", decl[:params][0][:internal]
    assert_equal "[AVCaptureDevice]", decl[:return_type]
  end

  def test_parses_instance_func_no_params
    line = "open func lockForConfiguration() throws"
    decl = @overlay.send(:parse_decl_line, line)
    refute_nil decl
    assert_equal :instance_func, decl[:kind]
    assert_equal "lockForConfiguration", decl[:name]
    assert_equal [], decl[:params]
  end

  def test_parses_init_with_params
    line = "public init(device: AVCaptureDevice)"
    decl = @overlay.send(:parse_decl_line, line)
    refute_nil decl
    assert_equal :init, decl[:kind]
    assert_equal "init", decl[:name]
    assert_equal 1, decl[:params].length
    assert_equal "device", decl[:params][0][:label]
    assert_equal "AVCaptureDevice", decl[:params][0][:type]
  end

  def test_parses_instance_var
    line = "open var category: String { get }"
    decl = @overlay.send(:parse_decl_line, line)
    refute_nil decl
    assert_equal :instance_var, decl[:kind]
    assert_equal "category", decl[:name]
    assert_equal [], decl[:params]
  end

  def test_parses_class_var
    line = "open class var shared: AVAudioSession { get }"
    decl = @overlay.send(:parse_decl_line, line)
    refute_nil decl
    assert_equal :class_var, decl[:kind]
    assert_equal "shared", decl[:name]
  end

  def test_returns_nil_for_unparseable_line
    line = "@available(macOS 10.7, *)"
    decl = @overlay.send(:parse_decl_line, line)
    assert_nil decl
  end

  def test_returns_nil_for_empty_line
    decl = @overlay.send(:parse_decl_line, "")
    assert_nil decl
  end

  # -- parse_params ----------------------------------------------------------

  def test_parse_params_single_labeled_param
    params = @overlay.send(:parse_params, "for mediaType: AVMediaType")
    assert_equal 1, params.length
    assert_equal "for", params[0][:label]
    assert_equal "mediaType", params[0][:internal]
    assert_equal "AVMediaType", params[0][:type]
  end

  def test_parse_params_underscore_label
    params = @overlay.send(:parse_params, "_ flag: Bool")
    assert_equal 1, params.length
    assert_equal "_", params[0][:label]
    assert_equal "flag", params[0][:internal]
  end

  def test_parse_params_multiple_params
    params = @overlay.send(:parse_params, "for mediaType: AVMediaType, position: Int")
    assert_equal 2, params.length
    assert_equal "for", params[0][:label]
    assert_equal "position", params[1][:label]
  end

  def test_parse_params_empty_string
    params = @overlay.send(:parse_params, "")
    assert_equal [], params
  end

  def test_parse_params_nil
    params = @overlay.send(:parse_params, nil)
    assert_equal [], params
  end
end
