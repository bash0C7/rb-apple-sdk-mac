# frozen_string_literal: true
require "apple_sdk_mac"

AppleSDKMac.bootstrap!

K_AUDIO_OBJECT_SYSTEM_OBJECT          = 1
K_AUDIO_HARDWARE_PROPERTY_DEVICES     = 0x64657623
K_AUDIO_OBJECT_PROPERTY_SCOPE_GLOBAL  = 0x676c6f62
K_AUDIO_OBJECT_PROPERTY_ELEMENT_MAIN  = 0

addr = {
  "mSelector" => K_AUDIO_HARDWARE_PROPERTY_DEVICES,
  "mScope"    => K_AUDIO_OBJECT_PROPERTY_SCOPE_GLOBAL,
  "mElement"  => K_AUDIO_OBJECT_PROPERTY_ELEMENT_MAIN
}

bytes = Apple::CoreAudio.AudioObjectGetPropertyDataSize(
  K_AUDIO_OBJECT_SYSTEM_OBJECT, addr, 0, nil
)
puts "audio devices: #{bytes / 4}"
