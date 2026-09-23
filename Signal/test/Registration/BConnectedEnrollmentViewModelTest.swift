// Copyright 2026 BConnected contributors. SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import XCTest
#if !SWIFT_PACKAGE
@testable import Signal
#endif
import SignalServiceKit

final class BConnectedEnrollmentViewModelTest: XCTestCase {
    @MainActor
    func testDeferredAccountFlowsDoNotConstructServicesEvenWithValidOrigins() {
        let model = BConnectedEnrollmentViewModel(info: ["BConnectedEnrollmentOrigin": "https://enrollment.example.invalid", "BConnectedCommunityOrigin": "https://community.example.invalid"], initialRegistration: false,
            makeCoordinator: { _ in fatalError("Deferred flow must not construct enrollment") },
            makeCommunity: { _, _, _ in fatalError("Deferred flow must not construct membership") })
        model.perform(.begin)
        model.applyPhone()
        model.connectMembership()
        model.publishAccount()
        model.publishPreKeys()
        model.verifyPublishedAccount()
        XCTAssertFalse(model.mayVerifyPublishedAccount)
        XCTAssertFalse(model.mayPublishPreKeys)
        XCTAssertFalse(model.mayPublishAccount)
        XCTAssertNil(model.progress)
        XCTAssertNil(model.communityProgress)
        XCTAssertFalse(model.canApply)
        XCTAssertFalse(model.busy)
        XCTAssertEqual(model.title, "Account setup unavailable")
    }

    @MainActor
    func testMissingOrInvalidEndpointDoesNotConstructServiceOrDispatch() {
        for info: [String: Any] in [[:], ["BConnectedEnrollmentOrigin": "http://example.invalid"], ["BConnectedEnrollmentOrigin": "https://example.invalid/legacy"]] {
            var constructions = 0
            let model = BConnectedEnrollmentViewModel(info: info) { _ in
                constructions += 1
                fatalError("An invalid config must not construct an enrollment service")
            }
            model.perform(.begin)
            model.perform(.sendCode)
            model.publishAccount()
            model.publishPreKeys()
            model.verifyPublishedAccount()
            XCTAssertFalse(model.mayVerifyPublishedAccount)
            XCTAssertFalse(model.mayPublishPreKeys)
            XCTAssertFalse(model.mayPublishAccount)
            XCTAssertEqual(constructions, 0)
            XCTAssertFalse(model.busy)
            XCTAssertNil(model.progress)
            XCTAssertNotNil(model.message)
        }
    }
}
