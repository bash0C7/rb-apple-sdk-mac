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
