# frozen_string_literal: true

require "yaml"

module AppleSDKMac
  module CallbackPillarCodegen
    def self.generate(yaml_path)
      sigs = YAML.load_file(yaml_path)
      out = +"import Foundation\n"
      sigs.flat_map { |s| Array(s["frameworks"]) }.uniq.sort.each { |f| out << "import #{f}\n" }
      out << "\nextension CallbackPillar {\n    public enum Signature: String {\n"
      sigs.each { |s| out << "        case #{s["token"]}\n" }
      out << "    }\n}\n\n"
      sigs.each { |s| out << emit_signature(s) }
      out.chomp + "\n"
    end

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
      params = s.fetch("swift_params")

      lines = []
      lines << "nonisolated(unsafe) fileprivate var _slots_#{tok}: [UInt64?] = Array(repeating: nil, count: #{n})"
      lines << "fileprivate let _slots_#{tok}_lock = NSLock()"

      n.times do |i|
        lines << ""
        lines << "fileprivate func _callback_pillar_#{tok}_slot_#{i}(#{params}) {"
        lines << "    guard let procId = _slots_#{tok}[#{i}] else { return }"
        lines << "    let arg: Int64 = #{arg_expr}"
        lines << "    ThreadingBridge.enqueueFromAppleThread(procId: procId, arg: arg)"
        lines << "}"
      end

      lines << ""
      lines << "extension CallbackPillar {"
      lines << "    static func _register_#{tok}(procId: UInt64) -> (slot: Int, fnptr: #{type})? {"
      lines << "        _slots_#{tok}_lock.withLock {"
      lines << "            guard let i = _slots_#{tok}.firstIndex(where: { $0 == nil }) else { return nil }"
      lines << "            _slots_#{tok}[i] = procId"
      lines << "            let fnptrs: [#{type}] = ["
      n.times { |i| lines << "                _callback_pillar_#{tok}_slot_#{i}," }
      lines << "            ]"
      lines << "            return (i, fnptrs[i])"
      lines << "        }"
      lines << "    }"
      lines << ""
      lines << "    static func _unregister_#{tok}(slot: Int) {"
      lines << "        _slots_#{tok}_lock.withLock {"
      lines << "            _slots_#{tok}[slot] = nil"
      lines << "        }"
      lines << "    }"
      lines << "}"
      lines << ""
      lines << "@c(runtime_callback_pillar_register_#{c_tok})"
      lines << "public func runtime_callback_pillar_register_#{c_tok}(_ procId: UInt64) -> Int32 {"
      lines << "    guard let r = CallbackPillar._register_#{tok}(procId: procId) else { return -1 }"
      lines << "    return Int32(r.slot)"
      lines << "}"
      lines << ""
      lines << "@c(runtime_callback_pillar_get_#{c_tok}_fnptr)"
      lines << "public func runtime_callback_pillar_get_#{c_tok}_fnptr(_ slot: Int32) -> UInt64 {"
      lines << "    let fnptrs: [#{type}] = ["
      n.times { |i| lines << "        _callback_pillar_#{tok}_slot_#{i}," }
      lines << "    ]"
      lines << "    let p = unsafeBitCast(fnptrs[Int(slot)], to: UnsafeRawPointer.self)"
      lines << "    return UInt64(UInt(bitPattern: p))"
      lines << "}"
      lines << ""
      lines << "@c(runtime_callback_pillar_unregister_#{c_tok})"
      lines << "public func runtime_callback_pillar_unregister_#{c_tok}(_ slot: Int32) {"
      lines << "    CallbackPillar._unregister_#{tok}(slot: Int(slot))"
      lines << "}"
      lines.join("\n") + "\n\n"
    end
  end
end
