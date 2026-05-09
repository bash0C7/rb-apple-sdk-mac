# frozen_string_literal: true
require "test_helper"
require "apple_sdk_mac"

class AudioDeviceCountE2ETest < Test::Unit::TestCase
  # Phase 3 倒置: AudioObjectGetPropertyDataSize の prompt が 4089 tokens で
  # Foundation Model 4096 context limit を超える。 Phase 3 で IntMarshaller
  # out_handling 静的化が landed したら このテストを復活させて、
  # assert_equal "template" を使う (plan Task 3.2 Step 5)
  #
  # def test_bootstrap_then_audio_object_get_property_data_size
  #   AppleSDKMac.bootstrap!
  #   addr = { mSelector: 0x64657623, mScope: 0x676c6f62, mElement: 0 }
  #   bytes = Apple::CoreAudio.AudioObjectGetPropertyDataSize(1, addr, 0, nil)
  #   assert bytes.is_a?(Integer)
  #   assert bytes >= 0
  #   row = AppleSDKMac.glue_cache.lookup(framework: "CoreAudio", symbol: "AudioObjectGetPropertyDataSize")
  #   assert_equal "template", row[:generator]
  # end
end
