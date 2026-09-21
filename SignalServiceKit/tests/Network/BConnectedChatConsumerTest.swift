// Copyright 2026 BConnected contributors. SPDX-License-Identifier: AGPL-3.0-only

import LibSignalClient
import XCTest
@testable import SignalServiceKit

final class BConnectedChatConsumerTest: XCTestCase {
    func testDisabledAuthenticatedChatDoesNotReadCredentialsOrCallTransport() async {
        let transport = RecordingTransport(capabilities: .chatOnly.restricted(to: []))
        let consumer = BConnectedChatConsumer(transport: transport)
        var credentialsRead = 0
        await assertFailure(BConnectedTransportError.unavailable(.authenticatedChat)) {
            _ = try await consumer.connectAuthenticatedChat {
                credentialsRead += 1
                return ("username", "password", true, ["en"])
            }
        }
        XCTAssertEqual(credentialsRead, 0)
        XCTAssertNil(transport.authentication)
    }

    func testAuthenticatedChatForwardsPreparedValuesExactlyOnce() async {
        let transport = RecordingTransport(capabilities: .chatOnly)
        let consumer = BConnectedChatConsumer(transport: transport)
        var credentialsRead = 0
        await assertFailure(FixtureError.connection) {
            _ = try await consumer.connectAuthenticatedChat {
                credentialsRead += 1
                return ("fixture.1", "synthetic-password", false, ["es", "en"])
            }
        }
        XCTAssertEqual(credentialsRead, 1)
        XCTAssertEqual(transport.authentication?.username, "fixture.1")
        XCTAssertEqual(transport.authentication?.password, "synthetic-password")
        XCTAssertEqual(transport.authentication?.receiveStories, false)
        XCTAssertEqual(transport.authentication?.languages, ["es", "en"])
        XCTAssertEqual(transport.authenticatedCalls, 1)
    }

    func testCredentialProviderFailureDoesNotCallTransport() async {
        let transport = RecordingTransport(capabilities: .chatOnly)
        await assertFailure(FixtureError.credentials) {
            _ = try await BConnectedChatConsumer(transport: transport).connectAuthenticatedChat {
                throw FixtureError.credentials
            }
        }
        XCTAssertEqual(transport.authenticatedCalls, 0)
    }

    func testCancellationFromCredentialAcquisitionIsPreserved() async {
        let transport = RecordingTransport(capabilities: .chatOnly)
        do {
            _ = try await BConnectedChatConsumer(transport: transport).connectAuthenticatedChat {
                throw CancellationError()
            }
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(transport.authenticatedCalls, 0)
    }

    func testDisabledUnauthenticatedChatDoesNotReadProviderOrCallTransport() async {
        let transport = RecordingTransport(capabilities: .chatOnly.restricted(to: [.authenticatedChat]))
        var providerCalls = 0
        await assertFailure(BConnectedTransportError.unavailable(.unauthenticatedChat)) {
            _ = try await BConnectedChatConsumer(transport: transport).connectUnauthenticatedChat {
                providerCalls += 1
                return ["en"]
            }
        }
        XCTAssertEqual(providerCalls, 0)
        XCTAssertNil(transport.unauthenticatedLanguages)
    }

    func testUnauthenticatedChatForwardsLanguageSelection() async {
        let transport = RecordingTransport(capabilities: .chatOnly)
        await assertFailure(FixtureError.connection) {
            _ = try await BConnectedChatConsumer(transport: transport).connectUnauthenticatedChat { ["es", "en"] }
        }
        XCTAssertEqual(transport.unauthenticatedLanguages, ["es", "en"])
    }

    func testOwnedKeyTransparencyDenialPrecedesConnectionAcquisition() async {
        let transport = RecordingTransport(capabilities: .chatOnly)
        var connectionsAcquired = 0
        await assertFailure(BConnectedTransportError.unavailable(.keyTransparency)) {
            _ = try await BConnectedChatConsumer(transport: transport).withKeyTransparencyClient {
                connectionsAcquired += 1
                return 42
            }
        }
        XCTAssertEqual(connectionsAcquired, 0)
    }

    func testLegacyKeyTransparencyPreservesProviderResultAndFailure() async throws {
        let consumer = BConnectedChatConsumer(transport: RecordingTransport(capabilities: .legacy))
        let result = try await consumer.withKeyTransparencyClient { 42 }
        XCTAssertEqual(result, 42)
        await assertFailure(FixtureError.connection) {
            _ = try await consumer.withKeyTransparencyClient { throw FixtureError.connection }
        }
    }

    func testTerminalFailuresBlockLaterAttemptsWithoutProviderSideEffects() {
        for error in terminalErrors {
            var failure = BConnectedChatConnectionFailure()
            XCTAssertTrue(failure.record(error, forAuthenticationGeneration: failure.authenticationGeneration))
            var providerCalls = 0
            for _ in 0..<3 {
                XCTAssertThrowsError(try {
                    try failure.requireAvailable(capabilities: .chatOnly, for: .authenticatedChat)
                    providerCalls += 1
                }()) { XCTAssertEqual($0 as? BConnectedTransportError, error) }
            }
            XCTAssertEqual(providerCalls, 0)
        }
    }

    func testTransientFailureAndCancellationDoNotLatch() throws {
        var failure = BConnectedChatConnectionFailure()
        XCTAssertFalse(failure.record(FixtureError.connection, forAuthenticationGeneration: 0))
        XCTAssertFalse(failure.record(CancellationError(), forAuthenticationGeneration: 0))
        XCTAssertNil(failure.terminalError)
        try failure.requireAvailable(capabilities: .legacy, for: .authenticatedChat)
    }

    func testAuthChangesClearCredentialFailureButNeverWidenTransportPolicy() {
        for error in terminalErrors {
            var failure = BConnectedChatConnectionFailure()
            failure.record(error, forAuthenticationGeneration: 0)
            failure.authenticationDidChange()
            XCTAssertEqual(failure.authenticationGeneration, 1)
            XCTAssertEqual(failure.terminalError, error == .invalidChatCredentials ? nil : error)
            XCTAssertThrowsError(try failure.requireAvailable(capabilities: .chatOnly, for: .keyTransparency)) {
                XCTAssertEqual($0 as? BConnectedTransportError, .unavailable(.keyTransparency))
            }
        }
    }

    func testOldCredentialAttemptCannotBlockNewlyInstalledCredentials() throws {
        var failure = BConnectedChatConnectionFailure()
        let oldGeneration = failure.authenticationGeneration
        failure.authenticationDidChange()
        XCTAssertFalse(failure.record(BConnectedTransportError.invalidChatCredentials, forAuthenticationGeneration: oldGeneration))
        XCTAssertNil(failure.terminalError)
        try failure.requireAvailable(capabilities: .chatOnly, for: .authenticatedChat)
        // A genuine failure with the new credentials remains terminal until the next auth change.
        XCTAssertTrue(failure.record(BConnectedTransportError.invalidChatCredentials,
            forAuthenticationGeneration: failure.authenticationGeneration))
        XCTAssertThrowsError(try failure.requireAvailable(capabilities: .chatOnly, for: .authenticatedChat))
        // A configuration failure is independent of the credentials' generation.
        XCTAssertTrue(failure.record(BConnectedTransportError.invalidOwnedConfiguration,
            forAuthenticationGeneration: oldGeneration))
        failure.authenticationDidChange()
        XCTAssertEqual(failure.terminalError, .invalidOwnedConfiguration)
    }

    func testClearingOverrideInstallsImplicitCredentialsBeforeReopening() throws {
        var failure = BConnectedChatConnectionFailure()
        let explicitGeneration = failure.authenticationGeneration
        var credentials = "explicit-invalid"
        XCTAssertTrue(failure.record(BConnectedTransportError.invalidChatCredentials,
            forAuthenticationGeneration: explicitGeneration))

        // Failure while installing implicit credentials must not make the old explicit source
        // eligible again or move it to a new generation. This checks installation/reset ordering.
        XCTAssertThrowsError(try failure.authenticationDidChange { throw FixtureError.credentials })
        XCTAssertEqual(failure.authenticationGeneration, explicitGeneration)
        XCTAssertThrowsError(try failure.requireAvailable(capabilities: .chatOnly, for: .authenticatedChat))
        XCTAssertEqual(credentials, "explicit-invalid")

        failure.authenticationDidChange { credentials = "implicit-valid" }
        try failure.requireAvailable(capabilities: .chatOnly, for: .authenticatedChat)
        XCTAssertEqual(credentials, "implicit-valid")
        XCTAssertFalse(failure.record(BConnectedTransportError.invalidChatCredentials,
            forAuthenticationGeneration: explicitGeneration))
        try failure.requireAvailable(capabilities: .chatOnly, for: .authenticatedChat)
    }

    private var terminalErrors: [BConnectedTransportError] {
        [.unavailable(.authenticatedChat), .ownedLibsignalUnavailable, .invalidOwnedConfiguration, .invalidChatCredentials]
    }

    private func assertFailure<Failure: Error & Equatable>(
        _ expected: Failure, operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line
    ) async {
        do { try await operation(); XCTFail("Expected failure", file: file, line: line) }
        catch { XCTAssertEqual(error as? Failure, expected, file: file, line: line) }
    }
}

private enum FixtureError: Error, Equatable { case connection, credentials }

private final class RecordingTransport: BConnectedChatTransport {
    let capabilities: BConnectedTransportCapabilities
    var authentication: (username: String, password: String, receiveStories: Bool, languages: [String])?
    var authenticatedCalls = 0
    var unauthenticatedLanguages: [String]?

    init(capabilities: BConnectedTransportCapabilities) { self.capabilities = capabilities }

    func connectAuthenticatedChat(username: String, password: String, receiveStories: Bool, languages: [String]) async throws -> AuthenticatedChatConnection {
        authenticatedCalls += 1
        authentication = (username, password, receiveStories, languages)
        throw FixtureError.connection
    }

    func connectUnauthenticatedChat(languages: [String]) async throws -> UnauthenticatedChatConnection {
        unauthenticatedLanguages = languages
        throw FixtureError.connection
    }

    func connectProvisioning() async throws -> ProvisioningConnection { throw FixtureError.connection }
    func preconnectChat() async throws { throw FixtureError.connection }
    func networkDidChange() throws { throw FixtureError.connection }
}
