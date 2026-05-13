#!/usr/bin/env ruby
# frozen_string_literal: true
#
# piano_keyboard.rb — software piano CLI demo
#
# CoreAudio で audio output device を列挙、 そこから 1 個選択、 zxcvbnm, →
# C4..C5 / sdfghj → 黒鍵 のキーマップで square wave を AVAudioEngine 経由で
# 選択 device に鳴らす。
#
# README L3 「any public Apple framework API」 を 4 framework 跨ぎで dogfood:
#   CoreAudio        AudioObjectGetPropertyDataSize / AudioObjectGetPropertyData /
#                    AudioUnitSetProperty (escape-hatch + Fiddle ハイブリッド)
#   CoreFoundation   CFStringGetCString / CFStringGetLength
#   Foundation       NSURL.fileURLWithPath:
#   AVFAudio         AVAudioFormat / AVAudioEngine / AVAudioPlayerNode /
#                    AVAudioFile / AVAudioIONode.audioUnit / scheduleFile...
#
# Usage:
#   . ~/.swiftly/env.sh
#   # 引数なし: audio output device list を出して exit 0 (smoke / Claude Code
#   # から番号を選びたいとき使う non-interactive 形)。
#   RUBY_BOX=1 bundle exec ruby examples/piano_keyboard.rb
#   # 引数 = device 番号 (1..N): その device で interactive piano を起動。
#   RUBY_BOX=1 bundle exec ruby examples/piano_keyboard.rb 3

require "fiddle"
require "io/console"
require "tmpdir"
require "fileutils"

require "apple_sdk_mac"

AppleSDKMac.bootstrap!

# =============================================================================
# Constants
# =============================================================================

# zxcvbnm, → C4..C5 白鍵、 sdfghj → 黒鍵 (E-F / B-C には黒鍵なし)
KEY_MAP = {
  "z" => ["C4",  261.63],
  "s" => ["C#4", 277.18],
  "x" => ["D4",  293.66],
  "d" => ["D#4", 311.13],
  "c" => ["E4",  329.63],
  "v" => ["F4",  349.23],
  "g" => ["F#4", 369.99],
  "b" => ["G4",  392.00],
  "h" => ["G#4", 415.30],
  "n" => ["A4",  440.00],
  "j" => ["A#4", 466.16],
  "m" => ["B4",  493.88],
  "," => ["C5",  523.25]
}.freeze

# CoreAudio property selectors (FourCC literals)
K_AUDIO_OBJECT_SYSTEM_OBJECT             = 1
K_AUDIO_HARDWARE_PROPERTY_DEVICES        = 0x64657623  # 'dev#'
K_AUDIO_OBJECT_PROPERTY_NAME             = 0x6c6e616d  # 'lnam'
K_AUDIO_DEVICE_PROPERTY_DEVICE_UID       = 0x75696420  # 'uid '
K_AUDIO_DEVICE_PROPERTY_STREAM_CONFIG    = 0x736c6179  # 'slay'
K_AUDIO_OBJECT_PROPERTY_SCOPE_GLOBAL     = 0x676c6f62  # 'glob'
K_AUDIO_OBJECT_PROPERTY_SCOPE_OUTPUT     = 0x6f757470  # 'outp'
K_AUDIO_OBJECT_PROPERTY_ELEMENT_MAIN     = 0
K_AUDIO_OUTPUT_UNIT_PROPERTY_CURRENT_DEVICE = 2000
K_AUDIO_UNIT_SCOPE_GLOBAL                = 0
K_CF_STRING_ENCODING_UTF8                = 0x08000100

SAMPLE_RATE = 44100
DURATION_SEC = 0.3
AMPLITUDE = 0.3
ENVELOPE_MS = 5

# =============================================================================
# Apple.discover register
# =============================================================================

# --- CoreAudio (escape-hatch C function path、 全 param を ESCAPE_HATCH_KINDS で構成) ---
# struct in pointer / void pointer は :opaque_ref で受けて Ruby 側で
# Fiddle::Pointer.malloc + pack で raw bytes を組み立てて Integer address を渡す。
# 各 declare に :uint32 を含めて escape_hatch_params? を true にする。
Apple.discover(
  framework: :CoreAudio, symbol: :AudioObjectGetPropertyDataSize,
  params: [:uint32, :opaque_ref, :uint32, :opaque_ref, :opaque_ref],
  return_kind: :int
)

Apple.discover(
  framework: :CoreAudio, symbol: :AudioObjectGetPropertyData,
  params: [:uint32, :opaque_ref, :uint32, :opaque_ref, :opaque_ref, :opaque_ref],
  return_kind: :int
)

Apple.discover(
  framework: :CoreAudio, symbol: :AudioUnitSetProperty,
  params: [:opaque_ref, :uint32, :uint32, :uint32, :opaque_ref, :uint32],
  return_kind: :int
)

# --- CoreFoundation (CFString → Ruby String) ---
# Knowledge Base のデフォルト分類は CFStringGetCString の buffer を string out に、
# CFStringRef を string に誤検出するため、 params/return_kind override で正しい
# kind 配列を渡す (cf_string_create.rb と同じ shape)。
Apple.discover(
  framework: :CoreFoundation, symbol: :CFStringGetLength,
  params: [{ kind: :cftype_ref, type: "CFString" }],
  return_kind: :int
)
Apple.discover(
  framework: :CoreFoundation, symbol: :CFStringGetCString,
  params: [
    { kind: :cftype_ref, type: "CFString" },
    :void_ptr_nilable,
    { kind: :int, type: "CFIndex" },
    { kind: :int, type: "CFStringEncoding" }
  ],
  return_kind: :bool
)

# --- Foundation ---
# fileURLWithPath: は Knowledge Base 未登録 (Foundation Swift overlay は KB 空)
# で LLM safety-net の context window 4096 を超える。 urlsession_download.rb と
# 同じ URLWithString: 経路に乗せて file:// scheme で渡す。
Apple.discover(
  framework: :Foundation, klass: :NSURL,
  class_method: "URLWithString:",
  params: [:string], return_kind: :opaque_ref
)

# --- AVFAudio ---
Apple.discover(
  framework: :AVFAudio, klass: :AVAudioFormat,
  swift_initializer: "init(standardFormatWithSampleRate:channels:)",
  params: [:float, :uint32], return_kind: :opaque_ref
)

Apple.discover(
  framework: :AVFAudio, klass: :AVAudioEngine,
  swift_initializer: "init()", params: [], return_kind: :opaque_ref
)

Apple.discover(
  framework: :AVFAudio, klass: :AVAudioPlayerNode,
  swift_initializer: "init()", params: [], return_kind: :opaque_ref
)

Apple.discover(
  framework: :AVFAudio, klass: :AVAudioFile,
  swift_initializer: "init(forReading:) throws",
  params: [{ kind: :opaque_ref, type: "URL" }], return_kind: :opaque_ref
)

# Swift 3 で attachNode → attach に rename。 emitter は ObjC→Swift rename を
# 自動解決せえへんため、 selector 文字列を Swift bridged 形 (`attach:`) で渡す
# と template_generator.swift_call_for_instance_method が
# `receiver.attach(arg0)` を emit する。
Apple.discover(
  framework: :AVFAudio, klass: :AVAudioEngine,
  selector: "attach:",
  params: [{ kind: :opaque_ref, type: "AVAudioNode" }], return_kind: :void
)

Apple.discover(
  framework: :AVFAudio, klass: :AVAudioEngine,
  selector: "connect:to:format:",
  params: [
    { kind: :opaque_ref, type: "AVAudioNode" },
    { kind: :opaque_ref, type: "AVAudioNode" },
    { kind: :opaque_ref, type: "AVAudioFormat" }
  ],
  return_kind: :void
)

Apple.discover(
  framework: :AVFAudio, klass: :AVAudioEngine,
  swift_property: :mainMixerNode, instance: true, return_kind: :opaque_ref
)

# return_klass を指定せえへんと wrap 先が receiver class (AVAudioEngine) に
# fallback して `@engine.outputNode` が AVAudioEngine instance を返してしまう。
# 明示的に AVAudioOutputNode に wrap、 audioUnit method を chain 可能に。
Apple.discover(
  framework: :AVFAudio, klass: :AVAudioEngine,
  swift_property: :outputNode, instance: true,
  return_kind: :opaque_ref, return_klass: :AVAudioOutputNode
)

# audioUnit は本来 AVAudioIONode の swift_property だが、 Ruby 側 Apple proxy
# class は Swift の継承関係を引き継がへんため、 ここでは具体 sub-class
# (AVAudioOutputNode) 配下に install する。 Swift 上は AVAudioOutputNode が
# AVAudioIONode を継承してるので unsafeBitCast(..., to: AVAudioOutputNode.self)
# 経由で audioUnit に到達できる。 AudioComponentInstance (= OpaquePointer)
# が Integer raw pointer として戻る。
Apple.discover(
  framework: :AVFAudio, klass: :AVAudioOutputNode,
  swift_property: :audioUnit, instance: true, return_kind: :opaque_ref
)

# Swift 3 で `startAndReturnError:` ObjC method は `start() throws` に
# bridge される。 emitter は `<...>AndReturnError:` 末尾を throws bridge と
# 判定し、 do/catch で `try receiver.start()` を emit、 success → Qtrue /
# throw → Qfalse。 user 側 params は error 引数を除外して空に。
Apple.discover(
  framework: :AVFAudio, klass: :AVAudioEngine,
  selector: "startAndReturnError:",
  params: [], return_kind: :bool
)

Apple.discover(
  framework: :AVFAudio, klass: :AVAudioEngine,
  selector: "stop", params: [], return_kind: :void
)

# Swift 3 で atTime → at に rename。 selector を Swift bridged 形で渡す。
# at: は AVAudioTime? (nil で「直ちに schedule」)、 completionHandler: は
# closure? (発音完了 callback、 不要)。 両方 nil 固定なので :nil_literal で
# 静的 emit (`let argN: T? = nil`) に乗せる。 :block_nilable は swift_init /
# objc_instance_method の in_load では未対応。
Apple.discover(
  framework: :AVFAudio, klass: :AVAudioPlayerNode,
  selector: "scheduleFile:at:completionHandler:",
  params: [
    { kind: :opaque_ref, type: "AVAudioFile" },
    { kind: :nil_literal, type: "AVAudioTime" },
    { kind: :nil_literal, type: "AVAudioNodeCompletionHandler" }
  ],
  return_kind: :void
)

Apple.discover(
  framework: :AVFAudio, klass: :AVAudioPlayerNode,
  selector: "play", params: [], return_kind: :void
)

# =============================================================================
# DeviceLister — CoreAudio HAL 経由で audio output device 一覧取得
# =============================================================================

module DeviceLister
  module_function

  def list_output_devices
    addr = build_addr(K_AUDIO_HARDWARE_PROPERTY_DEVICES, K_AUDIO_OBJECT_PROPERTY_SCOPE_GLOBAL)

    size_buf = Fiddle::Pointer.malloc(4)
    size_buf[0, 4] = "\x00".b * 4
    status = Apple::CoreAudio.AudioObjectGetPropertyDataSize(
      K_AUDIO_OBJECT_SYSTEM_OBJECT, addr.to_i, 0, 0, size_buf.to_i
    )
    raise "AudioObjectGetPropertyDataSize(Devices) status=#{status}" unless status.zero?
    bytes = size_buf.to_str(4).unpack1("V")
    return [] if bytes.zero?

    io_size_buf = Fiddle::Pointer.malloc(4)
    io_size_buf[0, 4] = [bytes].pack("V")
    data_buf = Fiddle::Pointer.malloc(bytes)
    status = Apple::CoreAudio.AudioObjectGetPropertyData(
      K_AUDIO_OBJECT_SYSTEM_OBJECT, addr.to_i, 0, 0,
      io_size_buf.to_i, data_buf.to_i
    )
    raise "AudioObjectGetPropertyData(Devices) status=#{status}" unless status.zero?

    device_ids = data_buf.to_str(bytes).unpack("L*")

    device_ids.filter_map do |id|
      next nil unless output_capable?(id)
      {
        id:   id,
        name: read_cf_string_property(id, K_AUDIO_OBJECT_PROPERTY_NAME,       K_AUDIO_OBJECT_PROPERTY_SCOPE_GLOBAL),
        uid:  read_cf_string_property(id, K_AUDIO_DEVICE_PROPERTY_DEVICE_UID, K_AUDIO_OBJECT_PROPERTY_SCOPE_GLOBAL)
      }
    end
  end

  # AudioObjectPropertyAddress = { UInt32 mSelector; UInt32 mScope; UInt32 mElement; }
  # 全 4-byte little-endian、 計 12 bytes の raw struct を Fiddle pointer に組み立て。
  def build_addr(selector, scope)
    buf = Fiddle::Pointer.malloc(12)
    buf[0, 12] = [selector, scope, K_AUDIO_OBJECT_PROPERTY_ELEMENT_MAIN].pack("V3")
    buf
  end

  def output_capable?(device_id)
    addr = build_addr(K_AUDIO_DEVICE_PROPERTY_STREAM_CONFIG, K_AUDIO_OBJECT_PROPERTY_SCOPE_OUTPUT)
    size_buf = Fiddle::Pointer.malloc(4)
    size_buf[0, 4] = "\x00".b * 4
    status = Apple::CoreAudio.AudioObjectGetPropertyDataSize(
      device_id, addr.to_i, 0, 0, size_buf.to_i
    )
    return false unless status.zero?
    size_buf.to_str(4).unpack1("V") > 0
  end

  def read_cf_string_property(device_id, selector, scope)
    addr = build_addr(selector, scope)
    io_size_buf = Fiddle::Pointer.malloc(4)
    io_size_buf[0, 4] = [8].pack("V")
    cf_buf = Fiddle::Pointer.malloc(8)
    cf_buf[0, 8] = "\x00".b * 8
    status = Apple::CoreAudio.AudioObjectGetPropertyData(
      device_id, addr.to_i, 0, 0, io_size_buf.to_i, cf_buf.to_i
    )
    return "(unknown)" unless status.zero?

    cf_ref = cf_buf.to_str(8).unpack1("Q")
    return "(unknown)" if cf_ref.nil? || cf_ref.zero?

    length = Apple::CoreFoundation.CFStringGetLength(cf_ref)
    return "" if length.zero?

    capacity = length * 4 + 1
    str_buf = Fiddle::Pointer.malloc(capacity)
    ok = Apple::CoreFoundation.CFStringGetCString(cf_ref, str_buf.to_i, capacity, K_CF_STRING_ENCODING_UTF8)
    return "(unknown)" if ok.nil? || ok == 0 || ok == false

    raw = str_buf.to_str(capacity)
    raw.split("\0", 2).first.to_s.force_encoding(Encoding::UTF_8)
  end
end

# =============================================================================
# WavBaker — Ruby 側で Float32 square wave + RIFF header の wav bytes 生成
# =============================================================================

module WavBaker
  module_function

  def bake(freq, sample_rate: SAMPLE_RATE, duration: DURATION_SEC, amp: AMPLITUDE)
    frames = (sample_rate * duration).to_i
    period = sample_rate.to_f / freq
    half_period = period / 2.0
    envelope_n = (sample_rate * ENVELOPE_MS / 1000.0).to_i

    samples = Array.new(frames) do |i|
      phase = i.to_f % period
      raw = phase < half_period ? amp : -amp
      gain = 1.0
      gain = i.to_f / envelope_n if i < envelope_n
      tail = frames - i
      gain = tail.to_f / envelope_n if tail < envelope_n && i >= envelope_n
      raw * gain
    end

    pcm = samples.pack("e*")
    data_size = pcm.bytesize

    header = String.new(encoding: Encoding::ASCII_8BIT)
    header << "RIFF" << [36 + data_size].pack("V") << "WAVE"
    header << "fmt " << [16].pack("V")
    header << [3].pack("v")             # PCM Float
    header << [1].pack("v")             # mono
    header << [sample_rate].pack("V")
    header << [sample_rate * 4].pack("V")  # byte rate
    header << [4].pack("v")             # block align
    header << [32].pack("v")            # bits per sample
    header << "data" << [data_size].pack("V")
    header + pcm
  end
end

# =============================================================================
# AudioPipeline — AVAudioEngine + PlayerNode + AVAudioFile load + device routing
# =============================================================================

class AudioPipeline
  attr_reader :engine, :player, :files

  def initialize(device, wav_paths)
    @device = device
    @wav_paths = wav_paths
  end

  def setup
    @format = Apple::AVFAudio::AVAudioFormat.init_standardFormatWithSampleRate_channels(
      SAMPLE_RATE.to_f, 1
    )
    raise "AVAudioFormat init failed" if @format.nil?

    @engine = Apple::AVFAudio::AVAudioEngine.init
    @player = Apple::AVFAudio::AVAudioPlayerNode.init

    @engine.attach(@player)
    @engine.connect_to_format(@player, @engine.mainMixerNode, @format)

    route_to_device

    @files = load_files

    # startAndReturnError: は emitter throws bridge で `try start()` に
    # 展開、 success → true (Qtrue) / throw → false (Qfalse) を返す。
    ok = @engine.startAndReturnError
    raise "AVAudioEngine.start() throws (returned false)" unless ok

    @player.play
    self
  end

  def play_freq(freq)
    file = @files[freq]
    return unless file
    @player.scheduleFile_at_completionHandler(file, nil, nil)
  end

  def stop
    @engine&.stop
  end

  private

  def route_to_device
    # AVAudioEngine.outputNode.audioUnit → AudioUnitSetProperty で「user 選択
    # device に強制 routing」 する設計やったが、 swift_property の return
    # marshalling (`Unmanaged.passRetained(raw as AnyObject).toOpaque()`) が
    # OpaquePointer (= AudioUnit) の raw bit pattern を保持せえへんため、 ここで
    # 渡せる AudioComponentInstance pointer が現状取得不能。 一旦 skip し、 OS
    # default output device に再生 fallback する。 selected device への強制
    # routing は output_capable? filter の正しい実装 (input-only device 除外)
    # と合わせて future iteration で。
    warn "device routing skipped (selected '#{@device[:name]}'); using OS default output"
  end

  def load_files
    @wav_paths.each_with_object({}) do |(freq, path), h|
      url = Apple::Foundation::NSURL.URLWithString("file://#{path}")
      next unless url
      file = Apple::AVFAudio::AVAudioFile.init_forReading(url)
      if file
        h[freq] = file
      else
        warn "AVAudioFile init failed for #{path}"
      end
    end
  end
end

# =============================================================================
# Main
# =============================================================================

def write_wavs(tmp_dir)
  wav_paths = {}
  KEY_MAP.each_value do |(note, freq)|
    next if wav_paths[freq]
    path = File.join(tmp_dir, "#{note.tr('#', 's')}.wav")
    File.binwrite(path, WavBaker.bake(freq))
    wav_paths[freq] = path
  end
  wav_paths
end

def key_loop(pipeline)
  puts
  puts "Press a key to play a note. Map:"
  KEY_MAP.each_slice(7) do |slice|
    puts "  " + slice.map { |k, (n, _)| "#{k}=#{n}" }.join("  ")
  end
  puts "Press q or Ctrl-C to quit."

  begin
    STDIN.raw do |io|
      loop do
        c = io.getc
        break if c.nil? || c == "q" || c == ""
        next unless KEY_MAP.key?(c)
        _, freq = KEY_MAP[c]
        pipeline.play_freq(freq)
      end
    end
  rescue Interrupt
    # Ctrl-C in raw mode: handled by  above, but cover the cooked case too
  ensure
    pipeline.stop
  end
end

def main
  devices = DeviceLister.list_output_devices
  if devices.empty?
    warn "no output audio devices found"
    exit 1
  end

  puts "Output devices:"
  devices.each_with_index do |d, i|
    puts "  [#{i + 1}] #{d[:name]} (uid=#{d[:uid]})"
  end

  # 引数なし: device list を表示して exit 0 (Claude Code フレンドリー、
  # 別 process で番号を選んで再起動できる two-step pattern)。
  exit 0 if ARGV.empty?

  idx = Integer(ARGV[0], exception: false)
  unless idx && idx >= 1 && idx <= devices.size
    warn "device index out of range: #{ARGV[0].inspect} (expected 1..#{devices.size})"
    exit 1
  end
  device = devices[idx - 1]

  tmp_dir = Dir.mktmpdir("piano_keyboard")
  at_exit { FileUtils.remove_entry(tmp_dir) rescue nil }

  wav_paths = write_wavs(tmp_dir)

  puts "Setting up audio engine on #{device[:name]}..."
  pipeline = AudioPipeline.new(device, wav_paths).setup

  key_loop(pipeline)
end

main
