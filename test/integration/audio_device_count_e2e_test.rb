# frozen_string_literal: true
require "test_helper"
require "apple_sdk_mac"

class AudioDeviceCountE2ETest < Test::Unit::TestCase
  def test_bootstrap_then_audio_object_get_property_data_size
    AppleSDKMac.bootstrap!
    addr = { mSelector: 0x64657623, mScope: 0x676c6f62, mElement: 0 }
    bytes = Apple::CoreAudio.AudioObjectGetPropertyDataSize(1, addr, 0, nil)
    assert bytes.is_a?(Integer)
    assert bytes >= 0
    # Phase 2 段階では LLM 経由のはず:
    row = AppleSDKMac.glue_cache.lookup(framework: "CoreAudio", symbol: "AudioObjectGetPropertyDataSize")
    assert_equal "llm", row[:generator] if row
  end
end
