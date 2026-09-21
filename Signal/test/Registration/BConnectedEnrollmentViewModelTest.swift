// Copyright 2026 BConnected contributors. SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import XCTest
#if !SWIFT_PACKAGE
@testable import Signal
#endif
import SignalServiceKit

final class BConnectedEnrollmentViewModelTest: XCTestCase {
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
            XCTAssertEqual(constructions, 0)
            XCTAssertFalse(model.busy)
            XCTAssertNil(model.progress)
            XCTAssertNotNil(model.message)
        }
    }
}
