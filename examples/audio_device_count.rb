# frozen_string_literal: true
# CoreAudio audio device count via transparent dispatch + LLM safety net.
# AudioObjectGetPropertyDataSize は KB に居るが outDataSize の int out param が
# 静的 emitter で対応外 → safety net が template を nil 戻し → LLM 生成経路で
# Swift glue が出る。 Phase 3 で IntMarshaller が静的化されるとこの example は
# 自動的に template generator 経由に切り替わる (出力は同じ)。
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
  mSelector: K_AUDIO_HARDWARE_PROPERTY_DEVICES,
  mScope:    K_AUDIO_OBJECT_PROPERTY_SCOPE_GLOBAL,
  mElement:  K_AUDIO_OBJECT_PROPERTY_ELEMENT_MAIN
}

bytes = Apple::CoreAudio.AudioObjectGetPropertyDataSize(
  K_AUDIO_OBJECT_SYSTEM_OBJECT, addr, 0, nil
)
puts "audio devices: #{bytes / 4}"
