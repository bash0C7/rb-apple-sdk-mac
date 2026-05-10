import Foundation
import CoreMIDI

// Per-signature register/unregister/slot tables and trampolines are emitted
// into CallbackPillarGenerated.swift by `rake runtime:codegen_callback_pillar`.
public enum CallbackPillar {
    public struct Handle {
        public let slot: Int
        public let signatureToken: String
    }
}

// === Persistent (escaping) block slot table ===
//
// Auto-incrementing slot ids; lifetime tied to BoxedBlockHandle on the Ruby
// side. Distinct from the typed per-signature slot pools in
// CallbackPillarGenerated.swift — those are statically-sized C-fnptr tables;
// this one is for @convention(block) closures whose signatures vary per
// Apple API and whose count is unbounded over a process lifetime.
nonisolated(unsafe) fileprivate var _blockPersistentSlots: [UInt64: UInt64] = [:]
nonisolated(unsafe) fileprivate var _blockPersistentNextId: UInt64 = 1
fileprivate let _blockPersistentLock = NSLock()

@c
public func runtime_callback_register_block_persistent(_ procId: UInt64) -> UInt64 {
    _blockPersistentLock.lock()
    defer { _blockPersistentLock.unlock() }
    let id = _blockPersistentNextId
    _blockPersistentNextId &+= 1
    _blockPersistentSlots[id] = procId
    return id
}

@c
public func runtime_callback_unregister_block_persistent(_ slotId: UInt64) {
    _blockPersistentLock.lock()
    defer { _blockPersistentLock.unlock() }
    _blockPersistentSlots.removeValue(forKey: slotId)
}

@c
public func runtime_callback_release_auto_block(_ slotId: UInt64) {
    runtime_callback_unregister_block_persistent(slotId)
}

// Returns the procId associated with a persistent block slot, or 0 if the
// slot has been released. Used by per-signature glue code (T9 onward) to
// fetch the Ruby Proc identity at Apple-callback time and route through
// ThreadingBridge.enqueueFromAppleThread.
@c
public func runtime_callback_lookup_block_persistent_procid(_ slotId: UInt64) -> UInt64 {
    _blockPersistentLock.lock()
    defer { _blockPersistentLock.unlock() }
    return _blockPersistentSlots[slotId] ?? 0
}

// Boxed handle whose deinit auto-unregisters the persistent slot. Per-symbol
// glue Swift returns instances of this class as the Ruby-visible value when
// the Apple API takes an escaping completion block; when the Ruby Box GC's,
// deinit fires and the slot is reclaimed.
public final class BoxedBlockHandle {
    public let slotId: UInt64
    public init(slotId: UInt64) { self.slotId = slotId }
    deinit { runtime_callback_release_auto_block(slotId) }
}
