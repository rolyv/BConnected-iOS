// Copyright 2026 BConnected contributors. SPDX-License-Identifier: AGPL-3.0-only

/// Policy for existing Signal URLSession routes, separate from private GCS capability requests.
struct BConnectedURLSessionPolicy {
    let capabilities: BConnectedTransportCapabilities

    /// The capability gate precedes configuration/DB reads as well as session construction.
    func withServiceSession<Value>(requiring capability: BConnectedTransportCapability,
                                   frontingRequested: () -> Bool, build: (Bool) throws -> Value) throws -> Value {
        try capabilities.require(capability)
        let requested = frontingRequested()
        try requireFrontingIfRequested(requested)
        return try build(requested)
    }

    func requireCdn(_ cdnNumber: UInt32) throws {
        switch cdnNumber {
        case 0, 2: try capabilities.require(.legacyCdn)
        case 3: try capabilities.require(.cdn3)
        default: throw BConnectedTransportError.invalidOwnedConfiguration
        }
    }

    func requireFrontingIfRequested(_ requested: Bool) throws {
        if requested { try capabilities.require(.domainFronting) }
    }

    /// Both callbacks can have side effects; service denial must precede either callback.
    func withCdnSession<Value>(
        cdnNumber: UInt32,
        frontingRequested: () -> Bool,
        build: (Bool) async throws -> Value
    ) async throws -> Value {
        try requireCdn(cdnNumber)
        let requested = frontingRequested()
        try requireFrontingIfRequested(requested)
        return try await build(requested)
    }

    func updateNativeFronting(enabled: Bool, apply: (Bool) throws -> Void) throws {
        if enabled { try capabilities.require(.domainFronting) }
        guard capabilities.allows(.domainFronting) else { return }
        try apply(enabled)
    }
}
