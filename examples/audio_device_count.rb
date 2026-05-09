# frozen_string_literal: true
# CoreAudio audio device count via transparent dispatch (static template path).
# AudioObjectGetPropertyDataSize の outDataSize は int out param、 inAddress は
# AudioObjectPropertyAddress struct in。 IntMarshaller#out_handling と
# StructInPointerMarshaller の Hash 入力経路で静的 emitter が完結する。
#
# Usage:
#   . ~/.swiftly/env.sh
#   RUBY_BOX=1 bundle exec ruby examples/audio_device_count.rb
require "apple_sdk_mac"

AppleSDKMac.bootstrap!

K_AUDIO_OBJECT_SYSTEM_OBJECT          = 1
K_AUDIO_HARDWARE_PROPERTY_DEVICES     = 0x64657623  # 'dev#'
K_AUDIO_OBJECT_PROPERTY_SCOPE_GLOBAL  = 0x676c6f62  # 'glob'
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
