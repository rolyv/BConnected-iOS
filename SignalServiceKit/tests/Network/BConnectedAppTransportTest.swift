// Copyright 2026 BConnected contributors. SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import LibSignalClient
import XCTest
@testable import SignalServiceKit

final class BConnectedAppTransportTest: XCTestCase {
    private var info: [String: Any] { [
        "BConnectedMessagingHost": "localhost",
        "BConnectedMessagingPort": "8443",
        "BConnectedMessagingTrust": "system",
    ] }

    func testEveryEndpointAndTrustInputIsRequired() {
        assertInvalid([:])
        for key in info.keys {
            var incomplete = info
            incomplete.removeValue(forKey: key)
            assertInvalid(incomplete)
        }
    }

    func testExplicitSystemTrustAndPortArePreserved() throws {
        let configuration = try configuration(info)
        XCTAssertEqual(configuration.host, "localhost")
        XCTAssertEqual(configuration.port, 8443)
        XCTAssertEqual(configuration.userAgent, "BConnected fixture")
        guard case .system = configuration.trust else { return XCTFail("Wrong trust") }
    }

    func testHostCannotContainSchemePortPathWhitespaceOrEmptyLabels() {
        for host in ["", "https://localhost", "localhost:8443", "localhost/path", " localhost", "local host", ".localhost", "localhost.", "a..b", "-a", "a-", "é.example", "a\0b", String(repeating: "a", count: 64)] {
            var changed = info; changed["BConnectedMessagingHost"] = host
            assertInvalid(changed)
        }
    }

    func testPortRequiresExplicitCanonicalNonzeroUInt16String() {
        for port: Any in [0, 443, "", "0", "65536", "-1", "+443", "0443", " 443", "443 "] {
            var changed = info; changed["BConnectedMessagingPort"] = port
            assertInvalid(changed)
        }
    }

    func testUnknownMissingOrAmbiguousTrustDoesNotFallBackToSystem() {
        for trust: Any in ["", "System", "insecure", 0] {
            var changed = info; changed["BConnectedMessagingTrust"] = trust
            assertInvalid(changed)
        }
        var ambiguous = info
        ambiguous["BConnectedMessagingCertificateDERBase64"] = "AQID"
        assertInvalid(ambiguous)
        for certificate: Any in ["", "not base64", "====", 123] {
            var changed = info; changed["BConnectedMessagingTrust"] = "certificate"
            changed["BConnectedMessagingCertificateDERBase64"] = certificate
            assertInvalid(changed)
        }
        var absent = info; absent["BConnectedMessagingTrust"] = "certificate"
        assertInvalid(absent)
    }

    func testCertificateBytesPreservedForAuthoritativeNativeValidation() throws {
        var changed = info; changed["BConnectedMessagingTrust"] = "certificate"
        changed["BConnectedMessagingCertificateDERBase64"] = "AQID"
        let configuration = try configuration(changed)
        guard case .certificate(let der) = configuration.trust else { return XCTFail("Wrong trust") }
        XCTAssertEqual(der, Data([1, 2, 3]))
        XCTAssertThrowsError(try configuration.makeTransport()) {
            #if BCONNECTED_OWNED_LIBSIGNAL
            XCTAssertEqual($0 as? BConnectedTransportError, .invalidOwnedConfiguration)
            #else
            XCTAssertEqual($0 as? BConnectedTransportError, .ownedLibsignalUnavailable)
            #endif
        }
    }

    func testInvalidUserAgentCannotEnterNativeHeaders() {
        for agent in ["", "bad\r\nheader", "bad\0header", "bad\u{7f}header"] {
            XCTAssertThrowsError(try BConnectedOwnedTransportConfiguration(info: info, userAgent: agent)) {
                XCTAssertEqual($0 as? BConnectedTransportError, .invalidOwnedConfiguration)
            }
        }
    }

    func testOwnedCompositionNeverSelectsLegacyNet() throws {
        let configuration = try configuration(info)
        #if BCONNECTED_OWNED_LIBSIGNAL
        let transport = try configuration.makeTransport()
        XCTAssertFalse(transport is Net)
        XCTAssertEqual(Set(BConnectedTransportCapability.allCases.filter(transport.capabilities.allows)),
                       [.authenticatedChat, .unauthenticatedChat, .chatPreconnect, .networkChange])
        var updates = 0
        try transport.applyLegacyNetworkConfiguration { _ in updates += 1 }
        XCTAssertEqual(updates, 0)
        for capability in [BConnectedTransportCapability.phoneContactDiscovery, .remoteBackupRecovery, .provisioning] {
            XCTAssertThrowsError(try transport.requireLegacyService(capability)) {
                XCTAssertEqual($0 as? BConnectedTransportError, .unavailable(capability))
            }
        }
        #else
        XCTAssertThrowsError(try configuration.makeTransport()) {
            XCTAssertEqual($0 as? BConnectedTransportError, .ownedLibsignalUnavailable)
        }
        #endif
    }

    func testClaimingLegacyCapabilitiesCannotCreateLegacyFallback() {
        let impostor = FixtureTransport(capabilities: .legacy)
        var effects = 0
        XCTAssertThrowsError(try impostor.applyLegacyNetworkConfiguration { _ in effects += 1 }) {
            XCTAssertEqual($0 as? BConnectedTransportError, .invalidOwnedConfiguration)
        }
        XCTAssertThrowsError(try impostor.requireLegacyService(.phoneContactDiscovery)) {
            XCTAssertEqual($0 as? BConnectedTransportError, .invalidOwnedConfiguration)
        }
        XCTAssertEqual(effects, 0)
    }

    func testExplicitExistingLegacyInstanceRetainsIdentityAndConfigurationBehavior() throws {
        // Constructing Net does not connect; no network operation is invoked in this test.
        let legacy = Net(env: .staging, userAgent: "BConnected fixture", buildVariant: .production)
        XCTAssertTrue(try legacy.requireLegacyService(.phoneContactDiscovery) === legacy)
        XCTAssertTrue(try legacy.requireLegacyService(.remoteBackupRecovery) === legacy)
        var effects = 0
        try legacy.applyLegacyNetworkConfiguration {
            XCTAssertTrue($0 === legacy)
            effects += 1
        }
        XCTAssertEqual(effects, 1)
    }

    private func cryptographicInfo() throws -> [String: Any] {
        ["BConnectedGroupPublicParamsBase64": try ServerSecretParams.generate().getPublicParams().serialize().base64EncodedString(),
         "BConnectedSenderCertificateTrustRootsBase64": [PrivateKey.generate().publicKey.serialize().base64EncodedString()]]
    }

    func testOwnedCryptographicInputsArePreservedIndependentlyOfTLS() throws {
        var supplied = try cryptographicInfo()
        supplied["BConnectedMessagingTrust"] = "certificate"
        supplied["BConnectedMessagingCertificateDERBase64"] = "AQID"
        let configuration = try BConnectedOwnedCryptographicConfiguration(info: supplied)
        XCTAssertEqual(configuration.groupServerPublicParams.base64EncodedString(), supplied["BConnectedGroupPublicParamsBase64"] as? String)
        XCTAssertEqual(configuration.senderCertificateTrustRoots, supplied["BConnectedSenderCertificateTrustRootsBase64"] as? [String])
    }

    func testEveryCryptographicAuthorityInputIsRequiredWithoutFallback() throws {
        let valid = try cryptographicInfo()
        for key in valid.keys {
            var missing = valid; missing.removeValue(forKey: key)
            missing["BConnectedMessagingTrust"] = "system"
            missing["BConnectedMessagingCertificateDERBase64"] = valid["BConnectedGroupPublicParamsBase64"]
            assertInvalidCryptography(missing)
        }
        assertInvalidCryptography([:])
    }

    func testGroupParametersRequireCanonicalNativePublicEncoding() throws {
        let valid = try cryptographicInfo()
        let original = valid["BConnectedGroupPublicParamsBase64"] as! String
        let root = (valid["BConnectedSenderCertificateTrustRootsBase64"] as! [String])[0]
        for invalid: Any in ["", 1, "====", "AQID", original + "\n", root,
                             Data(repeating: 0, count: 4097).base64EncodedString(),
                             (Data(base64Encoded: original)! + Data([1])).base64EncodedString()] {
            var changed = valid; changed["BConnectedGroupPublicParamsBase64"] = invalid
            assertInvalidCryptography(changed)
        }
    }

    func testSenderRootsRequireDistinctBoundedNativePublicKeys() throws {
        let valid = try cryptographicInfo()
        let root = (valid["BConnectedSenderCertificateTrustRootsBase64"] as! [String])[0]
        for invalid: Any in [[], root, [1], [root, root], ["AQID"], [root + "\n"],
                             [valid["BConnectedGroupPublicParamsBase64"] as! String],
                             [Data(repeating: 0, count: 33).base64EncodedString()],
                             (0..<9).map { _ in PrivateKey.generate().publicKey.serialize().base64EncodedString() }] {
            var changed = valid; changed["BConnectedSenderCertificateTrustRootsBase64"] = invalid
            assertInvalidCryptography(changed)
        }
    }

    func testExplicitSenderRootRotationOrderIsPreserved() throws {
        var supplied = try cryptographicInfo()
        let roots = (0..<3).map { _ in PrivateKey.generate().publicKey.serialize().base64EncodedString() }
        supplied["BConnectedSenderCertificateTrustRootsBase64"] = roots
        XCTAssertEqual(try BConnectedOwnedCryptographicConfiguration(info: supplied).senderCertificateTrustRoots, roots)
    }

    private func assertInvalidCryptography(_ info: [String: Any], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try BConnectedOwnedCryptographicConfiguration(info: info), file: file, line: line) {
            XCTAssertEqual($0 as? BConnectedTransportError, .invalidOwnedConfiguration, file: file, line: line)
        }
    }

    private func configuration(_ info: [String: Any]) throws -> BConnectedOwnedTransportConfiguration {
        try BConnectedOwnedTransportConfiguration(info: info, userAgent: "BConnected fixture")
    }
    private func assertInvalid(_ info: [String: Any], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try configuration(info), file: file, line: line) {
            XCTAssertEqual($0 as? BConnectedTransportError, .invalidOwnedConfiguration, file: file, line: line)
        }
    }
}

private final class FixtureTransport: BConnectedChatTransport {
    let capabilities: BConnectedTransportCapabilities
    init(capabilities: BConnectedTransportCapabilities) { self.capabilities = capabilities }
    func connectAuthenticatedChat(username: String, password: String, receiveStories: Bool, languages: [String]) async throws -> AuthenticatedChatConnection { throw CancellationError() }
    func connectUnauthenticatedChat(languages: [String]) async throws -> UnauthenticatedChatConnection { throw CancellationError() }
    func connectProvisioning() async throws -> ProvisioningConnection { throw CancellationError() }
    func preconnectChat() async throws { throw CancellationError() }
    func networkDidChange() throws { throw CancellationError() }
}
