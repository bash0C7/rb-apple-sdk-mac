# frozen_string_literal: true
require "test_helper"
require "rb_apple_sdk_knowledge/importer/docc_parser"

class TestDoccParser < Test::Unit::TestCase
  def test_parse_inline_renderjson_extracts_abstract_text
    json = {
      "metadata" => {
        "title" => "MIDIClientCreate",
        "symbolKind" => "func"
      },
      "abstract" => [
        { "type" => "text", "text" => "Creates a new MIDI client." }
      ],
      "primaryContentSections" => []
    }
    parser = AppleSDKKnowledge::Importer::DoccParser.new
    sym = parser.from_render_json(json)
    assert_equal "MIDIClientCreate", sym[:name]
    assert_equal "Creates a new MIDI client.", sym[:documentation]
  end
end
