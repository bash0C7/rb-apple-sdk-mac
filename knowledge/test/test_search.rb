# frozen_string_literal: true
require "test_helper"
require "tmpdir"
require "fileutils"
require "digest"
require "rb_apple_sdk_knowledge/store"
require "rb_apple_sdk_knowledge/search"

class TestSearch < Test::Unit::TestCase
  def setup
    @tmpdir = Dir.mktmpdir
    @store = AppleSDKKnowledge::Store.open(File.join(@tmpdir, "kb.sqlite"))
    fw_id = @store.insert_framework(name: "CoreMIDI", swift_module: "CoreMIDI")
    [
      { name: "MIDIClientCreate", kind: "function", abi: "c",
        signature: "OSStatus MIDIClientCreate(CFStringRef name, ...)",
        documentation: "Creates a new MIDI client." },
      { name: "MIDIClientDispose", kind: "function", abi: "c",
        signature: "OSStatus MIDIClientDispose(MIDIClientRef client)",
        documentation: "Disposes a MIDI client." },
      { name: "MIDISend", kind: "function", abi: "c",
        signature: "OSStatus MIDISend(...)",
        documentation: "Sends MIDI events to a port." }
    ].each do |sym|
      @store.insert_symbol(
        framework_id: fw_id,
        name: sym[:name],
        kind: sym[:kind],
        abi: sym[:abi],
        signature: sym[:signature],
        documentation: sym[:documentation],
        content_hash: Digest::SHA256.hexdigest(sym[:name] + sym[:signature])
      )
    end
    @store.rebuild_fts!
  end

  def teardown
    @store.close
    FileUtils.rm_rf(@tmpdir)
  end

  def test_lexical_finds_partial_match_via_trigrams
    search = AppleSDKKnowledge::Search.new(@store)
    results = search.lexical(framework: "CoreMIDI", query: "MIDIClient")
    names = results.map { |r| r[:name] }
    assert_includes names, "MIDIClientCreate"
    assert_includes names, "MIDIClientDispose"
  end

  def test_lexical_filters_by_framework
    search = AppleSDKKnowledge::Search.new(@store)
    results = search.lexical(framework: "CoreMIDI", query: "MIDISend")
    assert_equal "CoreMIDI", results.first[:framework]
  end
end
