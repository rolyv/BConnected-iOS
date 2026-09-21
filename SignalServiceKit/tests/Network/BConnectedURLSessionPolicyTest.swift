// Copyright 2026 BConnected contributors. SPDX-License-Identifier: AGPL-3.0-only

import XCTest
@testable import SignalServiceKit

final class BConnectedURLSessionPolicyTest: XCTestCase {
    func testOwnedCDNsFailBeforeFrontingLookupCacheOrSessionConstruction() async {
        let policy = BConnectedURLSessionPolicy(capabilities: .chatOnly)
        for cdn: UInt32 in [0, 2, 3] {
            var lookups = 0
            var sessions = 0
            do {
                _ = try await policy.withCdnSession(cdnNumber: cdn, frontingRequested: {
                    lookups += 1; return true
                }) { _ in sessions += 1; return 42 }
                XCTFail("Expected unavailable service")
            } catch {
                XCTAssertEqual(error as? BConnectedTransportError, .unavailable(cdn == 3 ? .cdn3 : .legacyCdn))
            }
            XCTAssertEqual(lookups, 0)
            XCTAssertEqual(sessions, 0)
        }
    }

    func testUnknownCDNNeverFallsBackForEitherMode() async {
        for capabilities in [BConnectedTransportCapabilities.legacy, .chatOnly] {
            for cdn: UInt32 in [1, 4, UInt32.max] {
                var sideEffects = 0
                do {
                    _ = try await BConnectedURLSessionPolicy(capabilities: capabilities).withCdnSession(
                        cdnNumber: cdn, frontingRequested: { sideEffects += 1; return false }
                    ) { _ in sideEffects += 1; return 42 }
                    XCTFail("Expected invalid route")
                } catch { XCTAssertEqual(error as? BConnectedTransportError, .invalidOwnedConfiguration) }
                XCTAssertEqual(sideEffects, 0)
            }
        }
    }

    func testSupportedLegacyCDNsPreserveResultAndFrontingSnapshot() async throws {
        let policy = BConnectedURLSessionPolicy(capabilities: .legacy)
        for cdn: UInt32 in [0, 2, 3] {
            for requested in [true, false] {
                let session = SessionFixture()
                var lookups = 0
                var builds = 0
                let returned = try await policy.withCdnSession(cdnNumber: cdn, frontingRequested: {
                    lookups += 1; return requested
                }) { captured in
                    XCTAssertEqual(captured, requested)
                    builds += 1
                    return session
                }
                XCTAssertTrue(returned === session)
                XCTAssertEqual(lookups, 1)
                XCTAssertEqual(builds, 1)
            }
        }
    }

    func testRestrictedFrontingFailsBeforeConstructionRatherThanUsingDirectRoute() async {
        let policy = BConnectedURLSessionPolicy(capabilities: .legacy.restricted(to: [.legacyCdn, .cdn3]))
        var builds = 0
        do {
            _ = try await policy.withCdnSession(cdnNumber: 2, frontingRequested: { true }) { _ in
                builds += 1; return 42
            }
            XCTFail("Expected unavailable fronting")
        } catch { XCTAssertEqual(error as? BConnectedTransportError, .unavailable(.domainFronting)) }
        XCTAssertEqual(builds, 0)
    }

    func testCapabilityRestrictionDoesNotAddLegacyCDNs() async throws {
        let policy = BConnectedURLSessionPolicy(capabilities: .legacy.restricted(to: [.cdn3]))
        XCTAssertThrowsError(try policy.requireCdn(0))
        XCTAssertThrowsError(try policy.requireCdn(2))
        let result = try await policy.withCdnSession(cdnNumber: 3, frontingRequested: { false }) { _ in 42 }
        XCTAssertEqual(result, 42)
        let owned = BConnectedURLSessionPolicy(capabilities: .chatOnly.restricted(to: Set(BConnectedTransportCapability.allCases)))
        XCTAssertThrowsError(try owned.requireCdn(3))
    }

    func testOwnedNativeFrontingIsNeverApplied() throws {
        let policy = BConnectedURLSessionPolicy(capabilities: .chatOnly)
        var calls: [Bool] = []
        try policy.updateNativeFronting(enabled: false) { calls.append($0) }
        XCTAssertThrowsError(try policy.updateNativeFronting(enabled: true) { calls.append($0) }) {
            XCTAssertEqual($0 as? BConnectedTransportError, .unavailable(.domainFronting))
        }
        XCTAssertEqual(calls, [])
    }

    func testLegacyNativeFrontingPreservesToggleAndFailure() throws {
        let policy = BConnectedURLSessionPolicy(capabilities: .legacy)
        var calls: [Bool] = []
        try policy.updateNativeFronting(enabled: true) { calls.append($0) }
        try policy.updateNativeFronting(enabled: false) { calls.append($0) }
        XCTAssertEqual(calls, [true, false])
        XCTAssertThrowsError(try policy.updateNativeFronting(enabled: true) { _ in throw FixtureError.build }) {
            XCTAssertTrue($0 is FixtureError)
        }
    }

    func testBuilderFailureAndCancellationAreNotTurnedIntoFallbackOrSuccess() async {
        let policy = BConnectedURLSessionPolicy(capabilities: .legacy)
        for failure: any Error in [FixtureError.build, CancellationError()] {
            var builds = 0
            do {
                _ = try await policy.withCdnSession(cdnNumber: 2, frontingRequested: { false }) { _ -> Int in
                    builds += 1; throw failure
                }
                XCTFail("Expected original failure")
            } catch {
                if failure is CancellationError { XCTAssertTrue(error is CancellationError) }
                else { XCTAssertTrue(error is FixtureError) }
            }
            XCTAssertEqual(builds, 1)
        }
    }
}

private final class SessionFixture {}
private enum FixtureError: Error { case build }
