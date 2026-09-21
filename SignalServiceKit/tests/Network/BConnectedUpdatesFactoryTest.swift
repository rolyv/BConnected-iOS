// Copyright 2026 BConnected contributors. SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import XCTest
@testable import SignalServiceKit

final class BConnectedUpdatesFactoryTest: XCTestCase {
    func testOwnedUpdatesDeniedBeforeEndpointOrSessionFactory() {
        let service = OWSSignalServiceMock()
        service.transportCapabilities = .chatOnly
        service.isCensorshipCircumventionActive = true
        assertNoConstruction(service)
    }

    func testNarrowedLegacyUpdatesDeniedBeforeFactories() {
        let service = OWSSignalServiceMock()
        service.transportCapabilities = .legacy.restricted(to: [.authenticatedChat, .domainFronting])
        assertNoConstruction(service)
    }

    func testRemoteAllowedSetCannotAddOwnedUpdates() {
        let service = OWSSignalServiceMock()
        service.transportCapabilities = .chatOnly.restricted(to: Set(BConnectedTransportCapability.allCases))
        assertNoConstruction(service)
    }

    func testLegacyUpdatesPreserveEndpointAndSessionIdentity() throws {
        try assertLegacyFactory(isV2: false)
    }

    func testLegacyUpdates2PreserveEndpointAndSessionIdentity() throws {
        try assertLegacyFactory(isV2: true)
    }

    private func assertNoConstruction(_ service: OWSSignalServiceMock, file: StaticString = #filePath, line: UInt = #line) {
        var endpointCalls = 0
        var sessionCalls = 0
        service.urlEndpointBuilder = { info in
            endpointCalls += 1
            return self.endpoint(for: info)
        }
        service.mockUrlSessionBuilder = { _, endpoint, _ in
            sessionCalls += 1
            return BaseOWSURLSessionMock(endpoint: endpoint, configuration: .ephemeral)
        }
        XCTAssertThrowsError(try service.urlSessionForUpdates(), file: file, line: line) {
            XCTAssertEqual($0 as? BConnectedTransportError, .unavailable(.updates), file: file, line: line)
        }
        XCTAssertThrowsError(try service.urlSessionForUpdates2(), file: file, line: line) {
            XCTAssertEqual($0 as? BConnectedTransportError, .unavailable(.updates), file: file, line: line)
        }
        XCTAssertEqual(endpointCalls, 0, file: file, line: line)
        XCTAssertEqual(sessionCalls, 0, file: file, line: line)
    }

    private func assertLegacyFactory(isV2: Bool) throws {
        let service = OWSSignalServiceMock()
        var endpointCalls = 0
        var sessionCalls = 0
        var builtSession: BaseOWSURLSessionMock?
        service.urlEndpointBuilder = { info in
            endpointCalls += 1
            XCTAssertEqual(info.baseUrl.absoluteString, isV2 ? TSConstants.updates2URL : TSConstants.updatesURL)
            XCTAssertFalse(info.censorshipCircumventionSupported)
            switch (info.type, isV2) {
            case (.updates, false), (.updates2, true): break
            default: XCTFail("Unexpected service route")
            }
            return self.endpoint(for: info)
        }
        service.mockUrlSessionBuilder = { info, endpoint, configuration in
            sessionCalls += 1
            XCTAssertEqual(endpoint.baseUrl, info.baseUrl)
            XCTAssertNil(configuration)
            let session = BaseOWSURLSessionMock(endpoint: endpoint, configuration: .ephemeral)
            builtSession = session
            return session
        }
        let result = try isV2 ? service.urlSessionForUpdates2() : service.urlSessionForUpdates()
        XCTAssertTrue(result === builtSession)
        XCTAssertEqual(endpointCalls, 1)
        XCTAssertEqual(sessionCalls, 1)
    }

    private func endpoint(for info: SignalServiceInfo) -> OWSURLSessionEndpoint {
        OWSURLSessionEndpoint(baseUrl: info.baseUrl, frontingInfo: nil, securityPolicy: .systemDefault, extraHeaders: [:])
    }
}
