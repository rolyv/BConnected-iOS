// Copyright 2026 BConnected contributors. SPDX-License-Identifier: AGPL-3.0-only

public import Foundation
public import LibSignalClient

/// A small dependency boundary for chat users. Recovery/discovery/proxy APIs do not belong here.
/// Existing AppSetup composition has not yet switched to this protocol.
public protocol BConnectedChatTransport: AnyObject {
    var capabilities: BConnectedTransportCapabilities { get }

    func connectAuthenticatedChat(username: String, password: String, receiveStories: Bool, languages: [String]) async throws -> AuthenticatedChatConnection
    func connectUnauthenticatedChat(languages: [String]) async throws -> UnauthenticatedChatConnection
    func connectProvisioning() async throws -> ProvisioningConnection
    func preconnectChat() async throws
    func networkDidChange() throws
}

// Conformance alone never constructs a legacy Net or selects an upstream environment.
extension Net: BConnectedChatTransport {
    public var capabilities: BConnectedTransportCapabilities { .legacy }
}

public enum BConnectedChatTransportFactory {
    public enum Trust {
        case system
        case certificate(Data)
    }

    /// Requires the reviewed personal libsignal Swift sources, C header, and native archive.
    /// BCONNECTED_OWNED_LIBSIGNAL is intentionally absent from the checked-in app build settings.
    /// Without that explicitly integrated dependency this fails before any native allocation/I/O.
    /// Neither branch falls back to a Signal environment or treats missing services as successful.
    public static func owned(
        host: String,
        port: UInt16,
        trust: Trust,
        userAgent: String,
        restrictingTo allowed: Set<BConnectedTransportCapability> = Set(BConnectedTransportCapability.allCases)
    ) throws -> any BConnectedChatTransport {
        #if BCONNECTED_OWNED_LIBSIGNAL
        let nativeTrust: ChatOnlyNet.Trust
        switch trust {
        case .system: nativeTrust = .system
        case .certificate(let der): nativeTrust = .certificate(der)
        }
        let net: ChatOnlyNet
        do {
            // Native validation is authoritative, including DNS hostname, port, DER, and header rules.
            net = try ChatOnlyNet(host: host, port: port, trust: nativeTrust, userAgent: userAgent)
        } catch {
            throw BConnectedTransportError.invalidOwnedConfiguration
        }
        return OwnedTransport(net: net, capabilities: .chatOnly.restricted(to: allowed))
        #else
        throw BConnectedTransportError.ownedLibsignalUnavailable
        #endif
    }
}

#if BCONNECTED_OWNED_LIBSIGNAL
/// Private so an application caller cannot inject a legacy Net or wider capability set.
private final class OwnedTransport: BConnectedChatTransport {
    private let net: ChatOnlyNet
    let capabilities: BConnectedTransportCapabilities

    init(net: ChatOnlyNet, capabilities: BConnectedTransportCapabilities) {
        self.net = net
        self.capabilities = capabilities
    }

    func connectAuthenticatedChat(username: String, password: String, receiveStories: Bool, languages: [String]) async throws -> AuthenticatedChatConnection {
        try capabilities.require(.authenticatedChat)
        // The native bridge requires an ACI with an optional device ID (1...127) and
        // treats a malformed username as a programmer error. Validate before entering it.
        // Reject embedded NULs instead of allowing C-string truncation of credentials.
        guard !username.utf8.contains(0), !password.utf8.contains(0) else {
            throw BConnectedTransportError.invalidChatCredentials
        }
        let separator = username.lastIndex(of: ".")
        let aci = separator.map { String(username[..<$0]) } ?? username
        let device = separator.map { String(username[username.index(after: $0)...]) } ?? "1"
        guard !device.isEmpty, device.utf8.allSatisfy({ (48...57).contains($0) }),
              let deviceId = UInt8(device), (1...127).contains(deviceId),
              (try? Aci.parseFrom(serviceIdString: aci)) != nil
        else {
            throw BConnectedTransportError.invalidChatCredentials
        }
        return try await net.connectAuthenticatedChat(username: username, password: password, receiveStories: receiveStories, languages: languages)
    }

    func connectUnauthenticatedChat(languages: [String]) async throws -> UnauthenticatedChatConnection {
        try capabilities.require(.unauthenticatedChat)
        return try await net.connectUnauthenticatedChat(languages: languages)
    }

    func connectProvisioning() async throws -> ProvisioningConnection {
        try capabilities.require(.provisioning)
        return try await net.connectProvisioning()
    }

    func preconnectChat() async throws {
        try capabilities.require(.chatPreconnect)
        try await net.preconnectChat()
    }

    func networkDidChange() throws {
        try capabilities.require(.networkChange)
        try net.networkDidChange()
    }
}
#endif
