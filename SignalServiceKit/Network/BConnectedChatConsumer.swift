// Copyright 2026 BConnected contributors. SPDX-License-Identifier: AGPL-3.0-only

import LibSignalClient

/// Shared by the app's chat consumers so capability checks precede provider side effects.
struct BConnectedChatConsumer {
    let transport: any BConnectedChatTransport

    func connectAuthenticatedChat(
        prepare: () async throws -> (username: String, password: String, receiveStories: Bool, languages: [String])
    ) async throws -> AuthenticatedChatConnection {
        try transport.capabilities.require(.authenticatedChat)
        let parameters = try await prepare()
        return try await transport.connectAuthenticatedChat(
            username: parameters.username,
            password: parameters.password,
            receiveStories: parameters.receiveStories,
            languages: parameters.languages
        )
    }

    func connectUnauthenticatedChat(languages: () -> [String]) async throws -> UnauthenticatedChatConnection {
        try transport.capabilities.require(.unauthenticatedChat)
        return try await transport.connectUnauthenticatedChat(languages: languages())
    }

    func withKeyTransparencyClient<Value>(acquire: () async throws -> Value) async throws -> Value {
        try transport.capabilities.require(.keyTransparency)
        return try await acquire()
    }
}

/// Queue-confined by OWSChatConnection. A policy/configuration failure cannot recover by retrying.
/// Credentials may change during registration, so that failure resets only on an auth-state event.
struct BConnectedChatConnectionFailure {
    private(set) var terminalError: BConnectedTransportError?
    private(set) var authenticationGeneration: UInt64 = 0

    @discardableResult
    mutating func record(_ error: any Error, forAuthenticationGeneration generation: UInt64) -> Bool {
        guard let error = error as? BConnectedTransportError else { return false }
        // An older attempt must not poison credentials installed while it was completing.
        if error == .invalidChatCredentials, generation != authenticationGeneration { return false }
        terminalError = error
        return true
    }

    func requireAvailable(capabilities: BConnectedTransportCapabilities, for capability: BConnectedTransportCapability) throws {
        try capabilities.require(capability)
        if let terminalError { throw terminalError }
    }

    mutating func authenticationDidChange() {
        authenticationDidChange(install: {})
    }

    mutating func authenticationDidChange(install: () throws -> Void) rethrows {
        // Install the new credential source before making a failed connection eligible again.
        try install()
        authenticationGeneration &+= 1
        if terminalError == .invalidChatCredentials { terminalError = nil }
    }
}
