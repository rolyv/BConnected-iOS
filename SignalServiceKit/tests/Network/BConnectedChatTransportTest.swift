// Copyright 2026 BConnected contributors. SPDX-License-Identifier: AGPL-3.0-only

import Darwin
import Foundation
import LibSignalClient
import XCTest
@testable import SignalServiceKit

final class BConnectedChatTransportTest: XCTestCase {
    private typealias Capability = BConnectedTransportCapability
    private let chatOnly: Set<Capability> = [.authenticatedChat, .unauthenticatedChat, .provisioning, .chatPreconnect, .networkChange, .stories]

    func testChatOnlyPolicyExcludesEveryUnimplementedService() {
        let policy = BConnectedTransportCapabilities.chatOnly
        XCTAssertEqual(Set(Capability.allCases.filter(policy.allows)), chatOnly)
        for capability in Capability.allCases where !chatOnly.contains(capability) {
            assertUnavailable(capability) { try policy.require(capability) }
        }
    }

    func testPreferencesAndRemotePolicyCanOnlyNarrowCapabilities() {
        let policy = BConnectedTransportCapabilities.chatOnly
        XCTAssertEqual(policy.restricted(to: Set(Capability.allCases)), policy)
        let narrowed = policy.restricted(to: [.authenticatedChat, .proxy, .secureValueRecovery])
        XCTAssertTrue(narrowed.allows(.authenticatedChat))
        XCTAssertFalse(narrowed.allows(.unauthenticatedChat))
        XCTAssertFalse(narrowed.allows(.proxy))
        XCTAssertFalse(narrowed.allows(.secureValueRecovery))
        XCTAssertEqual(narrowed.restricted(to: Set(Capability.allCases)), narrowed)
        XCTAssertTrue(Capability.allCases.allSatisfy { !policy.restricted(to: []).allows($0) })
    }

    func testUnavailableServicesNeverExecuteSynchronousSideEffects() {
        var credentialsFetched = 0
        for capability in Capability.allCases where !chatOnly.contains(capability) {
            assertUnavailable(capability) {
                try BConnectedTransportCapabilities.chatOnly.perform(requiring: capability) {
                    credentialsFetched += 1
                }
            }
        }
        XCTAssertEqual(credentialsFetched, 0)
    }

    func testUnavailableServicesNeverExecuteAsyncTokenFetchOrOperation() async {
        var tokensFetched = 0
        for capability in Capability.allCases where !chatOnly.contains(capability) {
            await assertUnavailableAsync(capability) {
                try await BConnectedTransportCapabilities.chatOnly.performAsync(requiring: capability) {
                    tokensFetched += 1
                    await Task.yield()
                }
            }
        }
        XCTAssertEqual(tokensFetched, 0)
    }

    func testAllowedOperationPreservesReturnValueAndFailure() async throws {
        enum FixtureError: Error { case failed }
        let policy = BConnectedTransportCapabilities.chatOnly
        XCTAssertEqual(try policy.perform(requiring: .authenticatedChat) { 42 }, 42)
        let result = try await policy.performAsync(requiring: .unauthenticatedChat) { "fixture" }
        XCTAssertEqual(result, "fixture")
        XCTAssertThrowsError(try policy.perform(requiring: .authenticatedChat) { throw FixtureError.failed }) {
            XCTAssertTrue($0 is FixtureError)
        }
    }

    func testLegacyConformanceDoesNotRequireAnEnvironmentOrInstantiateNet() {
        let legacyType: any BConnectedChatTransport.Type = Net.self
        XCTAssertEqual(ObjectIdentifier(legacyType), ObjectIdentifier(Net.self))
    }

    #if BCONNECTED_OWNED_LIBSIGNAL
    func testOwnedFactoryCannotWidenCapabilities() throws {
        let transport = try BConnectedChatTransportFactory.owned(host: "localhost", port: 8443, trust: .system,
            userAgent: "BConnected local test", restrictingTo: Set(Capability.allCases))
        XCTAssertEqual(transport.capabilities, .chatOnly)
        try transport.networkDidChange() // Native notification, not a network connection.
        let restricted = try BConnectedChatTransportFactory.owned(host: "localhost", port: 8443, trust: .system,
            userAgent: "BConnected local test", restrictingTo: [.networkChange, .proxy, .keyTransparency])
        XCTAssertEqual(Set(Capability.allCases.filter(restricted.capabilities.allows)), [.networkChange])
    }

    func testOwnedFactoryUsesNativeValidationWithoutConnecting() {
        for host in ["", "https://localhost", "localhost:443", "127.0.0.1", "localhost/path", "signal.org", "chat.signal.org", "a\0b"] {
            XCTAssertThrowsError(try BConnectedChatTransportFactory.owned(host: host, port: 443, trust: .system, userAgent: "test")) {
                XCTAssertEqual($0 as? BConnectedTransportError, .invalidOwnedConfiguration)
            }
        }
        XCTAssertThrowsError(try BConnectedChatTransportFactory.owned(host: "localhost", port: 0, trust: .system, userAgent: "test"))
        XCTAssertThrowsError(try BConnectedChatTransportFactory.owned(host: "localhost", port: 443, trust: .certificate(Data([1, 2, 3])), userAgent: "test"))
        XCTAssertThrowsError(try BConnectedChatTransportFactory.owned(host: "localhost", port: 443, trust: .system, userAgent: "bad\r\nheader"))
    }

    func testDisabledNativeOperationsFailBeforeOpeningTheConfiguredSocket() async throws {
        let listener = try LoopbackTLSProbe()
        let transport = try BConnectedChatTransportFactory.owned(host: "localhost", port: listener.port, trust: .system,
            userAgent: "BConnected local test", restrictingTo: [])
        await assertUnavailableAsync(.authenticatedChat) {
            _ = try await transport.connectAuthenticatedChat(username: "fixture", password: "fixture", receiveStories: true, languages: [])
        }
        await assertUnavailableAsync(.unauthenticatedChat) { _ = try await transport.connectUnauthenticatedChat(languages: []) }
        await assertUnavailableAsync(.provisioning) { _ = try await transport.connectProvisioning() }
        await assertUnavailableAsync(.chatPreconnect) { try await transport.preconnectChat() }
        assertUnavailable(.networkChange) { try transport.networkDidChange() }
        XCTAssertFalse(listener.hasPendingConnection())
    }

    func testNativeOperationsUseTheConfiguredLoopbackPortAndRequireTls() async throws {
        // This proves native dispatch/port selection and TLS initiation, not successful TLS trust,
        // WebSocket, provisioning, gRPC, or deployed-ingress compatibility. The test peer closes
        // after ClientHello, so no HTTP authorization headers or application data are sent.
        for capability in [Capability.authenticatedChat, .unauthenticatedChat, .provisioning, .chatPreconnect] {
            let listener = try LoopbackTLSProbe()
            let transport = try BConnectedChatTransportFactory.owned(host: "localhost", port: listener.port,
                trust: .system, userAgent: "BConnected local test")
            let observation = Task { try await listener.firstTLSRecordHeader() }
            do {
                switch capability {
                case .authenticatedChat:
                    _ = try await transport.connectAuthenticatedChat(username: "00000000-0000-4000-8000-000000000001.1", password: "fixture", receiveStories: true, languages: ["en"])
                case .unauthenticatedChat: _ = try await transport.connectUnauthenticatedChat(languages: ["en"])
                case .provisioning: _ = try await transport.connectProvisioning()
                case .chatPreconnect: try await transport.preconnectChat()
                default: XCTFail("unexpected fixture operation")
                }
                XCTFail("The peer did not complete TLS; a connection must not succeed")
            } catch {
                XCTAssertFalse(error is BConnectedTransportError, "The permitted call must reach native libsignal")
            }
            let header = try await observation.value
            XCTAssertEqual(header.count, 5)
            XCTAssertEqual(header[0], 0x16) // TLS handshake record, not plaintext HTTP.
            XCTAssertEqual(header[1], 0x03)
        }
    }

    func testMalformedCredentialsFailBeforeNativeParsingOrConnection() async throws {
        let listener = try LoopbackTLSProbe()
        let transport = try BConnectedChatTransportFactory.owned(host: "localhost", port: listener.port,
            trust: .system, userAgent: "BConnected local test")
        let aci = "00000000-0000-4000-8000-000000000001"
        for (username, password) in [
            ("fixture", "fixture"), ("PNI:\(aci)", "fixture"), ("\(aci).0", "fixture"),
            ("\(aci).128", "fixture"), ("\(aci).256", "fixture"), ("\(aci).", "fixture"),
            ("\(aci).-1", "fixture"), ("\(aci).1.1", "fixture"), ("\(aci)\0", "fixture"),
            (aci, "fixture\0suffix"),
        ] {
            do {
                _ = try await transport.connectAuthenticatedChat(username: username, password: password, receiveStories: false, languages: [])
                XCTFail("Malformed credentials must not reach the native connection")
            } catch {
                XCTAssertEqual(error as? BConnectedTransportError, .invalidChatCredentials)
            }
        }
        XCTAssertFalse(listener.hasPendingConnection())
    }
    #else
    func testMissingOwnedDependencyFailsClosedBeforeAnyConnection() throws {
        let listener = try LoopbackTLSProbe()
        for host in ["localhost", "chat.signal.org", "https://malformed.example"] {
            XCTAssertThrowsError(try BConnectedChatTransportFactory.owned(host: host, port: listener.port, trust: .system, userAgent: "test")) {
                XCTAssertEqual($0 as? BConnectedTransportError, .ownedLibsignalUnavailable)
            }
        }
        XCTAssertFalse(listener.hasPendingConnection())
    }
    #endif

    private func assertUnavailable(_ capability: Capability, _ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) {
            XCTAssertEqual($0 as? BConnectedTransportError, .unavailable(capability), file: file, line: line)
        }
    }

    private func assertUnavailableAsync(_ capability: Capability, _ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await body(); XCTFail("Unavailable capability executed", file: file, line: line) }
        catch { XCTAssertEqual(error as? BConnectedTransportError, .unavailable(capability), file: file, line: line) }
    }
}

/// A loopback-only test peer with bounded reads. It never performs TLS or reads credentials.
private final class LoopbackTLSProbe: @unchecked Sendable {
    private let descriptor: Int32
    let port: UInt16

    init() throws {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var success = false
        defer { if !success { Darwin.close(fd) } }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd, 8) == 0 else { throw POSIXError(.EIO) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.getsockname(fd, $0, &length) }
        }
        guard result == 0 else { throw POSIXError(.EIO) }
        descriptor = fd
        port = UInt16(bigEndian: address.sin_port)
        success = true
    }

    deinit { Darwin.close(descriptor) }

    func hasPendingConnection() -> Bool {
        var check = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        return Darwin.poll(&check, 1, 0) > 0
    }

    func firstTLSRecordHeader() async throws -> [UInt8] {
        try await Task.detached { [self] in
            var check = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            guard Darwin.poll(&check, 1, 5000) > 0 else { throw POSIXError(.ETIMEDOUT) }
            let connection = Darwin.accept(descriptor, nil, nil)
            guard connection >= 0 else { throw POSIXError(.EIO) }
            defer { Darwin.close(connection) }
            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            guard Darwin.setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else {
                throw POSIXError(.EIO)
            }
            var bytes = [UInt8](repeating: 0, count: 5)
            let count = Darwin.recv(connection, &bytes, bytes.count, MSG_WAITALL)
            guard count == bytes.count else { throw POSIXError(.EIO) }
            return bytes
        }.value
    }
}
