// Copyright 2026 BConnected contributors. SPDX-License-Identifier: AGPL-3.0-only

import LibSignalClient
import XCTest
@testable import SignalServiceKit

final class BConnectedProvisioningConsumerTest: XCTestCase {
    func testDeniedProvisioningDoesNotPrepareKeysOrOpenSocket() async {
        let transport = ProvisioningTransport(capabilities: .chatOnly.restricted(to: [.authenticatedChat]))
        var preparations = 0
        do {
            _ = try await BConnectedProvisioningConsumer(transport: transport).connect {
                preparations += 1; return "synthetic-key-material"
            }
            XCTFail("Expected unavailable provisioning")
        } catch { XCTAssertEqual(error as? BConnectedTransportError, .unavailable(.provisioning)) }
        XCTAssertEqual(preparations, 0)
        XCTAssertEqual(transport.connects, 0)
    }

    func testPreparationErrorStopsBeforeSocketAndIsPreserved() async {
        let transport = ProvisioningTransport(capabilities: .chatOnly)
        do {
            _ = try await BConnectedProvisioningConsumer(transport: transport).connect { () -> Int in
                throw FixtureError.prepare
            }
            XCTFail("Expected preparation error")
        } catch { XCTAssertEqual(error as? FixtureError, .prepare) }
        XCTAssertEqual(transport.connects, 0)
    }

    func testAllowedPreparationOccursBeforeSingleNativeAttempt() async {
        for capabilities in [BConnectedTransportCapabilities.chatOnly, .legacy] {
            let transport = ProvisioningTransport(capabilities: capabilities)
            var prepared = false
            transport.beforeConnect = { XCTAssertTrue(prepared) }
            do {
                _ = try await BConnectedProvisioningConsumer(transport: transport).connect {
                    XCTAssertFalse(prepared)
                    prepared = true
                    return "synthetic-key-material"
                }
                XCTFail("Expected fixture native error")
            } catch { XCTAssertEqual(error as? FixtureError, .connect) }
            XCTAssertTrue(prepared)
            XCTAssertEqual(transport.connects, 1)
        }
    }

    func testAlreadyCancelledAttemptDoesNotPrepareOrConnect() async {
        let transport = ProvisioningTransport(capabilities: .chatOnly)
        let result = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            var preparations = 0
            do {
                _ = try await BConnectedProvisioningConsumer(transport: transport).connect {
                    preparations += 1; return 42
                }
                XCTFail("Expected cancellation")
            } catch { XCTAssertTrue(error is CancellationError) }
            return preparations
        }.value
        XCTAssertEqual(result, 0)
        XCTAssertEqual(transport.connects, 0)
    }

    func testCancellationDuringPreparationDoesNotOpenSocket() async {
        let transport = ProvisioningTransport(capabilities: .chatOnly)
        await Task {
            do {
                _ = try await BConnectedProvisioningConsumer(transport: transport).connect {
                    withUnsafeCurrentTask { $0?.cancel() }
                    return 42
                }
                XCTFail("Expected cancellation")
            } catch { XCTAssertTrue(error is CancellationError) }
        }.value
        XCTAssertEqual(transport.connects, 0)
    }

    func testNativeCancellationIsPropagatedWithoutAnotherAttempt() async {
        let transport = ProvisioningTransport(capabilities: .chatOnly)
        transport.failure = CancellationError()
        do {
            _ = try await BConnectedProvisioningConsumer(transport: transport).connect { 42 }
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(transport.connects, 1)
    }
}

private enum FixtureError: Error, Equatable { case prepare, connect }
private final class ProvisioningTransport: BConnectedChatTransport {
    let capabilities: BConnectedTransportCapabilities
    var connects = 0
    var beforeConnect: (() -> Void)?
    var failure: any Error = FixtureError.connect
    init(capabilities: BConnectedTransportCapabilities) { self.capabilities = capabilities }
    func connectProvisioning() async throws -> ProvisioningConnection {
        beforeConnect?()
        connects += 1
        throw failure
    }
    func connectAuthenticatedChat(username: String, password: String, receiveStories: Bool, languages: [String]) async throws -> AuthenticatedChatConnection { throw FixtureError.connect }
    func connectUnauthenticatedChat(languages: [String]) async throws -> UnauthenticatedChatConnection { throw FixtureError.connect }
    func preconnectChat() async throws { throw FixtureError.connect }
    func networkDidChange() throws { throw FixtureError.connect }
}
