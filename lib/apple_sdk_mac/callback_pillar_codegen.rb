# frozen_string_literal: true
require "yaml"

module AppleSDKMac
  module CallbackPillarCodegen
    HEADER_NOTE = "// AUTO-GENERATED — do not edit. Source: callback_signatures.yml.\n"

    def self.generate(yaml_path)
      sigs = YAML.load_file(yaml_path)
      out = +HEADER_NOTE
      out << "\nimport Foundation\n"
      sigs.flat_map { |s| Array(s["frameworks"]) }.uniq.sort.each { |f| out << "import #{f}\n" }
      out << "\nextension CallbackPillar {\n    public enum Signature: String {\n"
      sigs.each { |s| out << "        case #{s["token"]}\n" }
      out << "    }\n}\n\n"
      sigs.each { |s| out << emit_signature(s) }
      out
    end

    def self.emit_signature(s)
      tok = s["token"]
      n = Integer(s["pool_size"])
      type = s["swift_type"]
      arg_expr = s["arg_marshaller"]

      lines = []
      lines << "// === #{tok}, pool_size=#{n} ==="
      lines << "nonisolated(unsafe) fileprivate var _slots_#{tok}: [UInt64?] = Array(repeating: nil, count: #{n})"
      lines << "fileprivate let _slots_#{tok}_lock = NSLock()"

      n.times do |i|
        lines << ""
        lines << "@_silgen_name(\"_callback_pillar_#{tok}_slot_#{i}\")"
        lines << "public func _callback_pillar_#{tok}_slot_#{i}("
        lines << "    _ message: UnsafePointer<MIDINotification>,"
        lines << "    _ refCon: UnsafeMutableRawPointer?"
        lines << ") {"
        lines << "    guard let procId = _slots_#{tok}[#{i}] else { return }"
        lines << "    let arg: Int64 = #{arg_expr}"
        lines << "    ThreadingBridge.enqueueFromAppleThread(procId: procId, arg: arg)"
        lines << "}"
      end

      lines << ""
      lines << "extension CallbackPillar {"
      lines << "    static func _register_#{tok}(procId: UInt64) -> (slot: Int, fnptr: #{type})? {"
      lines << "        _slots_#{tok}_lock.lock()"
      lines << "        defer { _slots_#{tok}_lock.unlock() }"
      lines << "        for (i, v) in _slots_#{tok}.enumerated() where v == nil {"
      lines << "            _slots_#{tok}[i] = procId"
      lines << "            let fnptrs: [#{type}] = ["
      n.times { |i| lines << "                _callback_pillar_#{tok}_slot_#{i}," }
      lines << "            ]"
      lines << "            return (i, fnptrs[i])"
      lines << "        }"
      lines << "        return nil"
      lines << "    }"
      lines << ""
      lines << "    static func _unregister_#{tok}(slot: Int) {"
      lines << "        _slots_#{tok}_lock.lock()"
      lines << "        defer { _slots_#{tok}_lock.unlock() }"
      lines << "        _slots_#{tok}[slot] = nil"
      lines << "    }"
      lines << "}"
      lines.join("\n") + "\n\n"
    end
  end
end
