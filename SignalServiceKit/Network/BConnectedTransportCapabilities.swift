// Copyright 2026 BConnected contributors. SPDX-License-Identifier: AGPL-3.0-only

/// Application policy, not evidence that a remote service is deployed or reachable.
public enum BConnectedTransportCapability: String, CaseIterable, Sendable {
    case authenticatedChat
    case unauthenticatedChat
    case provisioning
    case chatPreconnect
    case networkChange
    case proxy
    case domainFronting
    case phoneContactDiscovery
    case secureValueRecovery
    case remoteBackupRecovery
    case keyTransparency
    case nativeNetworkRemoteConfig
    case storageService
    case updates
    case legacyCdn
    case cdn3
    case calls
    case captcha
}

public enum BConnectedTransportError: Error, Equatable {
    case unavailable(BConnectedTransportCapability)
    case ownedLibsignalUnavailable
    case invalidOwnedConfiguration
    case invalidChatCredentials
}

/// Immutable capabilities. There is no raw-bits initializer or mutable remote-config override.
public struct BConnectedTransportCapabilities: Equatable, Sendable {
    private let available: Set<BConnectedTransportCapability>

    private init(_ available: Set<BConnectedTransportCapability>) {
        self.available = available
    }

    /// Preserves existing upstream application policy for explicitly selected legacy transports.
    public static let legacy = Self(Set(BConnectedTransportCapability.allCases))
    public static let chatOnly = Self([
        .authenticatedChat, .unauthenticatedChat, .provisioning, .chatPreconnect, .networkChange,
    ])

    public func allows(_ capability: BConnectedTransportCapability) -> Bool {
        available.contains(capability)
    }

    /// A cached preference or remote policy can remove capabilities, never add them.
    public func restricted(to allowed: Set<BConnectedTransportCapability>) -> Self {
        Self(available.intersection(allowed))
    }

    public func require(_ capability: BConnectedTransportCapability) throws {
        guard allows(capability) else { throw BConnectedTransportError.unavailable(capability) }
    }

    /// Place token acquisition and all other side effects inside the closure.
    public func perform<Value>(requiring capability: BConnectedTransportCapability, _ operation: () throws -> Value) throws -> Value {
        try require(capability)
        return try operation()
    }

    /// Place token acquisition and all other side effects inside the closure.
    public func performAsync<Value>(requiring capability: BConnectedTransportCapability, _ operation: () async throws -> Value) async throws -> Value {
        try require(capability)
        return try await operation()
    }
}
