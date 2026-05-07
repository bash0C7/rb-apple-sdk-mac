# frozen_string_literal: true
require "test_helper"
require "reline"
require "apple_sdk_mac/irb"
require "apple_sdk_mac/irb/doc_dialog"

# DocDialog renders Reline::DialogRenderInfo from the hovered popup
# candidate's documentation. The proc form (#to_proc) plugs into
# Reline.add_dialog_proc(:show_doc, ...); the pure helpers (#render,
# #wrap_text) are tested directly without a DialogProcScope.
class TestDocDialog < Test::Unit::TestCase
  DocDialog = AppleSDKMac::IRB::DocDialog

  def make_resolver(map)
    res = Object.new
    res.define_singleton_method(:resolve) { |matched| map[matched] }
    res
  end

  def cursor(x, y)
    Reline::CursorPos.new(x, y)
  end

  def autocomplete_dialog(column:, width:)
    Struct.new(:column, :width).new(column, width)
  end

  def test_wrap_text_splits_on_word_boundary
    dialog = DocDialog.new(resolver: make_resolver({}))
    out = dialog.wrap_text("Adds the value to the array giving it a new largest index.", 20)
    assert_operator out.size, :>=, 2
    out.each { |line| assert_operator line.size, :<=, 20 }
  end

  def test_wrap_text_collapses_whitespace
    dialog = DocDialog.new(resolver: make_resolver({}))
    out = dialog.wrap_text("foo \n\n  bar    baz", 50)
    assert_equal ["foo bar baz"], out
  end

  def test_wrap_text_returns_empty_for_blank
    dialog = DocDialog.new(resolver: make_resolver({}))
    assert_equal [], dialog.wrap_text("", 30)
    assert_equal [], dialog.wrap_text("   \n\t  ", 30)
  end

  def test_render_returns_nil_for_unresolvable_matched
    dialog = DocDialog.new(resolver: make_resolver({}))
    out = dialog.render(matched: "String.length", cursor_pos: cursor(0, 0), max_height: 10)
    assert_nil out
  end

  def test_render_returns_dialog_info_for_resolved_doc
    dialog = DocDialog.new(resolver: make_resolver(
      "Apple::CoreFoundation::CFArrayAppendValue" => "Adds the value to the array."
    ))
    out = dialog.render(
      matched: "Apple::CoreFoundation::CFArrayAppendValue",
      cursor_pos: cursor(3, 5),
      max_height: 10
    )
    assert out.is_a?(Reline::DialogRenderInfo),
      "expected DialogRenderInfo, got #{out.class}"
    assert_includes out.contents, "Adds the value to the array."
  end

  def test_render_anchors_x_to_autocomplete_dialog_when_provided
    dialog = DocDialog.new(resolver: make_resolver(
      "Apple::CoreFoundation::CFArrayAppendValue" => "Doc text."
    ))
    ad = autocomplete_dialog(column: 5, width: 25)
    out = dialog.render(
      matched: "Apple::CoreFoundation::CFArrayAppendValue",
      autocomplete_dialog: ad, cursor_pos: cursor(0, 7), max_height: 10
    )
    assert_equal 30, out.pos.x  # 5 + 25
    assert_equal 7, out.pos.y
  end

  def test_render_truncates_to_max_height
    long_doc = (["This is a sentence."] * 50).join(" ")
    dialog = DocDialog.new(resolver: make_resolver("Apple::F::K.method" => long_doc))
    out = dialog.render(
      matched: "Apple::F::K.method", cursor_pos: cursor(0, 0), max_height: 3
    )
    assert_equal 3, out.contents.size
  end

  def test_to_proc_returns_callable
    dialog = DocDialog.new(resolver: make_resolver({}))
    p = dialog.to_proc
    assert p.is_a?(Proc)
  end

  def test_render_invokes_prefetcher_with_matched
    received = []
    pref = Object.new
    pref.define_singleton_method(:prefetch) { |matched| received << matched }
    dialog = DocDialog.new(
      resolver: make_resolver(
        "Apple::Foundation::URL.appendingPathComponent" => "Doc text."
      ),
      prefetcher: pref
    )
    dialog.render(
      matched: "Apple::Foundation::URL.appendingPathComponent",
      cursor_pos: cursor(0, 0), max_height: 10
    )
    assert_equal ["Apple::Foundation::URL.appendingPathComponent"], received
  end

  def test_render_invokes_prefetcher_even_when_no_doc
    # Apple SDK symbols that have no documentation populated still
    # benefit from prefetch (Swift-overlay frameworks return nil from
    # the resolver but the user is still about to call them).
    received = []
    pref = Object.new
    pref.define_singleton_method(:prefetch) { |matched| received << matched }
    dialog = DocDialog.new(resolver: make_resolver({}), prefetcher: pref)
    out = dialog.render(
      matched: "Apple::Foundation::URL.appendingPathComponent",
      cursor_pos: cursor(0, 0), max_height: 10
    )
    assert_nil out
    assert_equal ["Apple::Foundation::URL.appendingPathComponent"], received
  end
end
