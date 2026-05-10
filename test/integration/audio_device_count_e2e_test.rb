# frozen_string_literal: true
require "test_helper"
require "apple_sdk_mac"

class AudioDeviceCountE2ETest < Test::Unit::TestCase
  # Task 3.2 re-enable: IntMarshaller now has static out_handling, so
  # AudioObjectGetPropertyDataSize takes the template path (no LLM,
  # no 4096-token overflow). assert_equal "template" passes deterministically.
  def test_bootstrap_then_audio_object_get_property_data_size
    AppleSDKMac.bootstrap!
    # String keys required: rb_hash_aref in the generated Swift glue looks up
    # by string key (rb_str_new_cstr), so symbol keys { mSelector: ... } would
    # return Qnil and cause TypeError. Use string keys to match the glue contract.
    addr = { "mSelector" => 0x64657623, "mScope" => 0x676c6f62, "mElement" => 0 }
    bytes = Apple::CoreAudio.AudioObjectGetPropertyDataSize(1, addr, 0, nil)
    assert bytes.is_a?(Integer)
    assert bytes >= 0
    row = AppleSDKMac.glue_cache.lookup(framework: "CoreAudio", symbol: "AudioObjectGetPropertyDataSize")
    assert_equal "template", row[:generator]
  end
end
