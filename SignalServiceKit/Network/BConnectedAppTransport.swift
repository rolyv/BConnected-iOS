// Copyright 2026 BConnected contributors. SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import LibSignalClient

/// Public cryptographic inputs are independent of HTTPS trust and service addresses. Native
/// parsing proves format/canonical encoding only; deployment must establish their ownership.
struct BConnectedOwnedCryptographicConfiguration {
    let groupServerPublicParams: Data
    let senderCertificateTrustRoots: [String]

    init(info: [String: Any]) throws {
        do {
            let params = try Self.canonicalBase64(info["BConnectedGroupPublicParamsBase64"], maximumBytes: 4096)
            guard try ServerPublicParams(contents: params).serialize() == params,
                  let encodedRoots = info["BConnectedSenderCertificateTrustRootsBase64"] as? [String],
                  !encodedRoots.isEmpty, encodedRoots.count <= 8,
                  Set(encodedRoots).count == encodedRoots.count else {
                throw BConnectedTransportError.invalidOwnedConfiguration
            }
            for encoded in encodedRoots {
                let bytes = try Self.canonicalBase64(encoded, maximumBytes: 33)
                guard bytes.count == 33, try PublicKey(bytes).serialize() == bytes else {
                    throw BConnectedTransportError.invalidOwnedConfiguration
                }
            }
            groupServerPublicParams = params
            senderCertificateTrustRoots = encodedRoots
        } catch {
            // Never surface native parser details or configuration contents to startup logs.
            throw BConnectedTransportError.invalidOwnedConfiguration
        }
    }

    private static func canonicalBase64(_ value: Any?, maximumBytes: Int) throws -> Data {
        guard let encoded = value as? String, !encoded.isEmpty,
              encoded.utf8.count <= ((maximumBytes + 2) / 3) * 4,
              let bytes = Data(base64Encoded: encoded), !bytes.isEmpty, bytes.count <= maximumBytes,
              bytes.base64EncodedString() == encoded else {
            throw BConnectedTransportError.invalidOwnedConfiguration
        }
        return bytes
    }
}

/// Explicit public configuration inputs, supplied independently to the app and each extension.
/// No production host, probe certificate, or Signal environment is a default.
struct BConnectedOwnedTransportConfiguration {
    let host: String
    let port: UInt16
    let trust: BConnectedChatTransportFactory.Trust
    let userAgent: String

    init(info: [String: Any], userAgent: String) throws {
        guard let host = info["BConnectedMessagingHost"] as? String,
              !host.isEmpty, host.utf8.count <= 253,
              host.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 46 }),
              !host.split(separator: ".", omittingEmptySubsequences: false).contains(where: {
                  $0.isEmpty || $0.utf8.count > 63 || $0.first == "-" || $0.last == "-"
              }),
              let portString = info["BConnectedMessagingPort"] as? String,
              let port = UInt16(portString), port > 0, String(port) == portString,
              !userAgent.isEmpty, !userAgent.utf8.contains(where: { $0 < 32 || $0 == 127 }),
              let trustMode = info["BConnectedMessagingTrust"] as? String
        else { throw BConnectedTransportError.invalidOwnedConfiguration }

        switch trustMode {
        case "system":
            guard info["BConnectedMessagingCertificateDERBase64"] == nil else {
                throw BConnectedTransportError.invalidOwnedConfiguration
            }
            self.trust = .system
        case "certificate":
            guard let encoded = info["BConnectedMessagingCertificateDERBase64"] as? String,
                  !encoded.isEmpty, let der = Data(base64Encoded: encoded), !der.isEmpty,
                  der.base64EncodedString() == encoded
            else { throw BConnectedTransportError.invalidOwnedConfiguration }
            self.trust = .certificate(der)
        default:
            throw BConnectedTransportError.invalidOwnedConfiguration
        }
        self.host = host
        self.port = port
        self.userAgent = userAgent
    }

    /// One iPhone per alumnus in this pilot. Stories use the retained chat transport;
    /// this does not advertise that any Stories/media/server route is already deployed.
    static let pilotCapabilities: Set<BConnectedTransportCapability> = [
        .authenticatedChat, .unauthenticatedChat, .chatPreconnect, .networkChange,
    ]

    func makeTransport() throws -> any BConnectedChatTransport {
        try BConnectedChatTransportFactory.owned(
            host: host, port: port, trust: trust, userAgent: userAgent,
            restrictingTo: Self.pilotCapabilities
        )
    }
}

extension BConnectedChatTransport {
    /// Resolve only an explicitly selected existing legacy transport. Never create a fallback.
    func requireLegacyService(_ capability: BConnectedTransportCapability) throws -> Net {
        try capabilities.require(capability)
        guard let legacy = self as? Net else { throw BConnectedTransportError.invalidOwnedConfiguration }
        return legacy
    }

    /// App-level remote configuration still updates normally. Native route flags belong only
    /// to the legacy Net branch; an owned transport cannot acquire new routes from these flags.
    func applyLegacyNetworkConfiguration(_ update: (Net) -> Void) throws {
        guard capabilities.allows(.nativeNetworkRemoteConfig) else { return }
        try update(requireLegacyService(.nativeNetworkRemoteConfig))
    }
}
