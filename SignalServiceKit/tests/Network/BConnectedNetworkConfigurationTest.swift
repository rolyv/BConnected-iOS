// Copyright 2026 BConnected contributors. SPDX-License-Identifier: AGPL-3.0-only

import LibSignalClient
import CFNetwork
import Foundation
import XCTest
@testable import SignalServiceKit

final class BConnectedNetworkConfigurationTest: XCTestCase {
    private let proxy = BConnectedSystemProxy(scheme: "https", host: "proxy.example.invalid", port: 443,
                                             username: "synthetic-user", password: "synthetic-password")

    func testPACAndUnknownCandidatesFailClosedInOwnedModeWithoutFallback() {
        let unsupported: [NSDictionary] = [
            [kCFProxyTypeKey: kCFProxyTypeAutoConfigurationJavaScript],
            [kCFProxyTypeKey: kCFProxyTypeAutoConfigurationURL],
            [kCFProxyTypeKey: "future-proxy-type"],
            [:],
        ]
        for candidate in unsupported {
            let transport = ConfigurationTransport(capabilities: .chatOnly)
            let parsed = BConnectedSystemProxyParser.firstProxy(
                in: [candidate, [kCFProxyTypeKey: kCFProxyTypeNone]], rejectUnsupported: true
            )
            XCTAssertNotNil(parsed)
            XCTAssertThrowsError(try BConnectedNetworkConfiguration(transport: transport)
                .networkDidChange(inAppProxyEnabled: false) { parsed }) {
                XCTAssertEqual($0 as? BConnectedTransportError, .unavailable(.proxy))
            }
            XCTAssertEqual(transport.events, [])
        }
    }

    func testLegacyPACAndUnknownCandidatesContinueToExplicitDirectCandidate() {
        let proxies: [NSDictionary] = [
            [kCFProxyTypeKey: kCFProxyTypeAutoConfigurationURL],
            [kCFProxyTypeKey: "future-proxy-type"],
            [:],
            [kCFProxyTypeKey: kCFProxyTypeNone],
        ]
        XCTAssertNil(BConnectedSystemProxyParser.firstProxy(in: proxies, rejectUnsupported: false))
    }

    func testSystemParserHonorsDirectCandidateOrdering() {
        let proxies: [NSDictionary] = [
            [kCFProxyTypeKey: kCFProxyTypeNone],
            [kCFProxyTypeKey: kCFProxyTypeAutoConfigurationJavaScript],
        ]
        XCTAssertNil(BConnectedSystemProxyParser.firstProxy(in: proxies, rejectUnsupported: true))
    }

    func testSystemParserPreservesSupportedProxyFields() {
        for (type, expectedScheme) in [(kCFProxyTypeHTTP, "http"), (kCFProxyTypeHTTPS, "https"), (kCFProxyTypeSOCKS, "socks")] {
            let parsed = BConnectedSystemProxyParser.firstProxy(in: [[
                kCFProxyTypeKey: type,
                kCFProxyHostNameKey: "proxy.example.invalid",
                kCFProxyPortNumberKey: 443,
                kCFProxyUsernameKey: "synthetic-user",
                kCFProxyPasswordKey: "synthetic-password",
            ]], rejectUnsupported: true)
            XCTAssertEqual(parsed?.scheme, expectedScheme)
            XCTAssertEqual(parsed?.host, proxy.host)
            XCTAssertEqual(parsed?.port, proxy.port)
            XCTAssertEqual(parsed?.username, proxy.username)
            XCTAssertEqual(parsed?.password, proxy.password)
        }
    }

    func testOwnedInitializationWithoutProxyNeverCallsNativeProxyControls() throws {
        let transport = ConfigurationTransport(capabilities: .chatOnly)
        try BConnectedNetworkConfiguration(transport: transport).resetProxy(inAppProxyEnabled: false) { nil }
        XCTAssertEqual(transport.events, [])
    }

    func testOwnedRequestedProxyIsExplicitlyUnavailableBeforeNativeSideEffects() {
        for inApp in [true, false] {
            let transport = ConfigurationTransport(capabilities: .chatOnly)
            let config = BConnectedNetworkConfiguration(transport: transport)
            XCTAssertThrowsError(try config.resetProxy(inAppProxyEnabled: inApp) { self.proxy }) {
                XCTAssertEqual($0 as? BConnectedTransportError, .unavailable(.proxy))
            }
            XCTAssertThrowsError(try config.setSignalProxy(host: "proxy.example.invalid", port: 443)) {
                XCTAssertEqual($0 as? BConnectedTransportError, .unavailable(.proxy))
            }
            XCTAssertEqual(transport.events, [])
        }
    }

    func testOwnedNetworkChangeRejectsProxyBeforeNotifyingNativeTransport() {
        let transport = ConfigurationTransport(capabilities: .chatOnly)
        XCTAssertThrowsError(try BConnectedNetworkConfiguration(transport: transport)
            .networkDidChange(inAppProxyEnabled: false) { self.proxy }) {
            XCTAssertEqual($0 as? BConnectedTransportError, .unavailable(.proxy))
        }
        XCTAssertEqual(transport.events, [])
    }

    func testOwnedNetworkChangeWithoutProxyNotifiesOnlyNativeNetworkChange() throws {
        let transport = ConfigurationTransport(capabilities: .chatOnly)
        try BConnectedNetworkConfiguration(transport: transport).networkDidChange(inAppProxyEnabled: false) { nil }
        XCTAssertEqual(transport.events, ["network-change"])
    }

    func testDeniedNetworkChangeDoesNotReadSystemProxyOrTouchNativeState() {
        let transport = ConfigurationTransport(capabilities: .chatOnly.restricted(to: [.authenticatedChat]))
        var reads = 0
        XCTAssertThrowsError(try BConnectedNetworkConfiguration(transport: transport)
            .networkDidChange(inAppProxyEnabled: false) { reads += 1; return self.proxy }) {
            XCTAssertEqual($0 as? BConnectedTransportError, .unavailable(.networkChange))
        }
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(transport.events, [])
    }

    func testRequestGateRejectsBothProxySourcesAndNeverConfiguresNativeState() throws {
        let transport = ConfigurationTransport(capabilities: .chatOnly)
        let config = BConnectedNetworkConfiguration(transport: transport)
        var systemReads = 0
        XCTAssertThrowsError(try config.requireRequestedProxySupported(inAppProxyEnabled: true) {
            systemReads += 1; return nil
        })
        XCTAssertEqual(systemReads, 0)
        XCTAssertThrowsError(try config.requireRequestedProxySupported(inAppProxyEnabled: false) { self.proxy })
        try config.requireRequestedProxySupported(inAppProxyEnabled: false) { nil }
        XCTAssertEqual(transport.events, [])
    }

    func testLegacySystemProxyArgumentsAndOrderArePreserved() throws {
        let transport = ConfigurationTransport(capabilities: .legacy)
        try BConnectedNetworkConfiguration(transport: transport).networkDidChange(inAppProxyEnabled: false) { self.proxy }
        XCTAssertEqual(transport.events, ["system-proxy", "network-change"])
        XCTAssertEqual(transport.proxy?.scheme, proxy.scheme)
        XCTAssertEqual(transport.proxy?.host, proxy.host)
        XCTAssertEqual(transport.proxy?.port, proxy.port)
        XCTAssertEqual(transport.proxy?.username, proxy.username)
        XCTAssertEqual(transport.proxy?.password, proxy.password)
    }

    func testLegacyInAppProxyIsNotOverwrittenByReset() throws {
        let transport = ConfigurationTransport(capabilities: .legacy)
        let config = BConnectedNetworkConfiguration(transport: transport)
        try config.resetProxy(inAppProxyEnabled: true) { XCTFail("Must not inspect system proxy"); return self.proxy }
        try config.setSignalProxy(host: proxy.host, port: proxy.port)
        XCTAssertEqual(transport.events, ["signal-proxy"])
        XCTAssertEqual(transport.proxy?.host, proxy.host)
        XCTAssertEqual(transport.proxy?.port, proxy.port)
    }

    func testLegacyNoProxyAndInvalidSystemProxyPreserveClearPolicy() throws {
        let transport = ConfigurationTransport(capabilities: .legacy)
        let config = BConnectedNetworkConfiguration(transport: transport)
        try config.resetProxy(inAppProxyEnabled: false) { nil }
        transport.rejectProxy = true
        try config.networkDidChange(inAppProxyEnabled: false) { self.proxy }
        XCTAssertEqual(transport.events, ["clear-proxy", "system-proxy", "clear-proxy", "network-change"])
    }

    func testLegacyInvalidSignalProxyPropagatesWithoutClearOrDirectFallback() {
        let transport = ConfigurationTransport(capabilities: .legacy)
        transport.rejectProxy = true
        XCTAssertThrowsError(try BConnectedNetworkConfiguration(transport: transport)
            .setSignalProxy(host: proxy.host, port: proxy.port))
        XCTAssertEqual(transport.events, ["signal-proxy"])
    }
}

private final class ConfigurationTransport: BConnectedChatTransport, BConnectedNativeProxyControl {
    let capabilities: BConnectedTransportCapabilities
    var events: [String] = []
    var proxy: BConnectedSystemProxy?
    var rejectProxy = false
    init(capabilities: BConnectedTransportCapabilities) { self.capabilities = capabilities }

    func setProxy(scheme: String, host: String, port: UInt16?, username: String?, password: String?) throws {
        events.append("system-proxy")
        if rejectProxy { throw BConnectedTransportError.invalidOwnedConfiguration }
        proxy = .init(scheme: scheme, host: host, port: port, username: username, password: password)
    }
    func setProxy(host: String, port: UInt16?) throws {
        events.append("signal-proxy")
        if rejectProxy { throw BConnectedTransportError.invalidOwnedConfiguration }
        proxy = .init(scheme: "signal", host: host, port: port, username: nil, password: nil)
    }
    func clearProxy() { events.append("clear-proxy") }
    func networkDidChange() throws { events.append("network-change") }
    func connectAuthenticatedChat(username: String, password: String, receiveStories: Bool, languages: [String]) async throws -> AuthenticatedChatConnection {
        throw BConnectedTransportError.invalidOwnedConfiguration
    }
    func connectUnauthenticatedChat(languages: [String]) async throws -> UnauthenticatedChatConnection {
        throw BConnectedTransportError.invalidOwnedConfiguration
    }
    func connectProvisioning() async throws -> ProvisioningConnection { throw BConnectedTransportError.invalidOwnedConfiguration }
    func preconnectChat() async throws { throw BConnectedTransportError.invalidOwnedConfiguration }
}
