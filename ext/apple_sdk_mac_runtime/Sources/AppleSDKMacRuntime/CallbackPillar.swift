import Foundation

/// Slot tables that turn Ruby procs into C function pointers and Objective-C blocks.
///
/// The per-signature C function pointer pools live in `CallbackPillarGenerated.swift`, generated from `callback_signatures.yml` by `rake runtime:codegen_callback_pillar`.
public enum CallbackPillar {
    public struct Handle {
        public let slot: Int
        public let signatureToken: String
    }
}

nonisolated(unsafe) fileprivate var _blockPersistentSlots: [UInt64: UInt64] = [:]
nonisolated(unsafe) fileprivate var _blockPersistentNextId: UInt64 = 1
fileprivate let _blockPersistentLock = NSLock()

/// Registers the Ruby proc `procId` for an escaping block.
///
/// - Returns: A new slot id. Pass it to ``runtime_callback_unregister_block_persistent(_:)`` to release the slot.
@c(runtime_callback_register_block_persistent)
public func runtime_callback_register_block_persistent(_ procId: UInt64) -> UInt64 {
    _blockPersistentLock.withLock {
        let id = _blockPersistentNextId
        _blockPersistentNextId &+= 1
        _blockPersistentSlots[id] = procId
        return id
    }
}

/// Releases a slot returned by ``runtime_callback_register_block_persistent(_:)``.
@c(runtime_callback_unregister_block_persistent)
public func runtime_callback_unregister_block_persistent(_ slotId: UInt64) {
    _blockPersistentLock.withLock {
        _ = _blockPersistentSlots.removeValue(forKey: slotId)
    }
}

/// Releases the slot of a ``BoxedBlockHandle``.
@c(runtime_callback_release_auto_block)
public func runtime_callback_release_auto_block(_ slotId: UInt64) {
    runtime_callback_unregister_block_persistent(slotId)
}

/// Returns the Ruby proc id registered in `slotId`, or `0` when the slot has been released.
@c(runtime_callback_lookup_block_persistent_procid)
public func runtime_callback_lookup_block_persistent_procid(_ slotId: UInt64) -> UInt64 {
    _blockPersistentLock.withLock {
        _blockPersistentSlots[slotId] ?? 0
    }
}

/// Owns an escaping-block slot and releases it on deinitialization.
public final class BoxedBlockHandle {
    public let slotId: UInt64
    public init(slotId: UInt64) { self.slotId = slotId }
    deinit { runtime_callback_release_auto_block(slotId) }
}
