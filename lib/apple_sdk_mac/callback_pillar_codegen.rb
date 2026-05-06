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

    # Snake-case token, dropping trailing _proc / _block / _handler. Used for
    # the runtime_callback_pillar_register_<this> / get_fnptr / unregister
    # @c-bridged wrappers exposed to glue Swift via @_silgen_name.
    def self.c_token(token)
      snake = token.gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase
      snake.sub(/_(proc|block|handler|callback)\z/, "")
    end

    def self.emit_signature(s)
      tok = s["token"]
      n = Integer(s["pool_size"])
      type = s["swift_type"]
      arg_expr = s["arg_marshaller"]
      c_tok = s["c_wrapper_token"] || c_token(tok)
      # Phase 7 generalization: swift_params is the trampoline parameter list
      # embedded verbatim. Falls back to the legacy MIDINotifyProc shape so
      # existing YAML continues to work without per-entry edits.
      params = s["swift_params"] ||
               "_ message: UnsafePointer<MIDINotification>, _ refCon: UnsafeMutableRawPointer?"

      lines = []
      lines << "// === #{tok}, pool_size=#{n} ==="
      lines << "nonisolated(unsafe) fileprivate var _slots_#{tok}: [UInt64?] = Array(repeating: nil, count: #{n})"
      lines << "fileprivate let _slots_#{tok}_lock = NSLock()"

      n.times do |i|
        lines << ""
        lines << "@_silgen_name(\"_callback_pillar_#{tok}_slot_#{i}\")"
        lines << "public func _callback_pillar_#{tok}_slot_#{i}(#{params}) {"
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
      lines << ""
      # Per-token @c-bridged runtime_callback_pillar_* wrappers. Glue Swift
      # references these via @_silgen_name; one source of truth means adding
      # a new signature requires no manual RuntimeBridge.swift edits.
      lines << "@c"
      lines << "public func runtime_callback_pillar_register_#{c_tok}(_ procId: UInt64) -> Int32 {"
      lines << "    guard let r = CallbackPillar._register_#{tok}(procId: procId) else { return -1 }"
      lines << "    return Int32(r.slot)"
      lines << "}"
      lines << ""
      lines << "@c"
      lines << "public func runtime_callback_pillar_get_#{c_tok}_fnptr(_ slot: Int32) -> UInt64 {"
      lines << "    let fnptrs: [#{type}] = ["
      n.times { |i| lines << "        _callback_pillar_#{tok}_slot_#{i}," }
      lines << "    ]"
      lines << "    let p = unsafeBitCast(fnptrs[Int(slot)], to: UnsafeRawPointer.self)"
      lines << "    return UInt64(UInt(bitPattern: p))"
      lines << "}"
      lines << ""
      lines << "@c"
      lines << "public func runtime_callback_pillar_unregister_#{c_tok}(_ slot: Int32) {"
      lines << "    CallbackPillar._unregister_#{tok}(slot: Int(slot))"
      lines << "}"
      lines.join("\n") + "\n\n"
    end
  end
end
