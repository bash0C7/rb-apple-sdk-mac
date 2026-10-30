#!/usr/bin/env ruby
# frozen_string_literal: true

require "fiddle"
require "io/console"
require "tmpdir"
require "fileutils"

require "apple_sdk_mac"

AppleSDKMac.bootstrap!

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

K_AUDIO_OBJECT_SYSTEM_OBJECT             = 1
K_AUDIO_HARDWARE_PROPERTY_DEVICES        = 0x64657623
K_AUDIO_OBJECT_PROPERTY_NAME             = 0x6c6e616d
K_AUDIO_DEVICE_PROPERTY_DEVICE_UID       = 0x75696420
K_AUDIO_DEVICE_PROPERTY_STREAM_CONFIG    = 0x736c6179
K_AUDIO_OBJECT_PROPERTY_SCOPE_GLOBAL     = 0x676c6f62
K_AUDIO_OBJECT_PROPERTY_SCOPE_OUTPUT     = 0x6f757470
K_AUDIO_OBJECT_PROPERTY_ELEMENT_MAIN     = 0
K_AUDIO_OUTPUT_UNIT_PROPERTY_CURRENT_DEVICE = 2000
K_AUDIO_UNIT_SCOPE_GLOBAL                = 0
K_CF_STRING_ENCODING_UTF8                = 0x08000100

SAMPLE_RATE = 44100
DURATION_SEC = 0.3
AMPLITUDE = 0.3
ENVELOPE_MS = 5

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

Apple.discover(
  framework: :Foundation, klass: :NSURL,
  class_method: "URLWithString:",
  params: [:string], return_kind: :opaque_ref
)

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

Apple.discover(
  framework: :AVFAudio, klass: :AVAudioEngine,
  swift_property: :outputNode, instance: true,
  return_kind: :opaque_ref, return_klass: :AVAudioOutputNode
)

Apple.discover(
  framework: :AVFAudio, klass: :AVAudioOutputNode,
  swift_property: :audioUnit, instance: true, return_kind: :opaque_ref
)

Apple.discover(
  framework: :AVFAudio, klass: :AVAudioEngine,
  selector: "startAndReturnError:",
  params: [], return_kind: :bool
)

Apple.discover(
  framework: :AVFAudio, klass: :AVAudioEngine,
  selector: "stop", params: [], return_kind: :void
)

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
    header << [3].pack("v")
    header << [1].pack("v")
    header << [sample_rate].pack("V")
    header << [sample_rate * 4].pack("V")
    header << [4].pack("v")
    header << [32].pack("v")
    header << "data" << [data_size].pack("V")
    header + pcm
  end
end

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

  exit 0 if ARGV.empty?

  idx = Integer(ARGV[0], exception: false)
  unless idx && idx >= 1 && idx <= devices.size
    warn "device index out of range: #{ARGV[0].inspect} (expected 1..#{devices.size})"
    exit 1
  end
  device = devices[idx - 1]

  tmp_dir = Dir.mktmpdir("piano_keyboard")
  at_exit { FileUtils.rm_rf(tmp_dir) }

  wav_paths = write_wavs(tmp_dir)

  puts "Setting up audio engine on #{device[:name]}..."
  pipeline = AudioPipeline.new(device, wav_paths).setup

  key_loop(pipeline)
end

main
