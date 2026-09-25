// Copyright 2026 BConnected contributors. SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import LibSignalClient
import XCTest

@testable import SignalServiceKit

final class RegistrationIdMismatchManagerTest: XCTestCase {
    private let kvStore = NewKeyValueStore(collection: "RegistrationIdMismatchManagerImpl")

    func testExpectedLookupFailuresPreserveIdsAndRemainRetryable() async {
        let failures: [any Error] = [
            BConnectedTransportError.unavailable(.unauthenticatedChat),
            BConnectedTransportError.ownedLibsignalUnavailable,
            BConnectedTransportError.invalidOwnedConfiguration,
            BConnectedTransportError.invalidChatCredentials,
            OWSHTTPError.networkFailure(.genericFailure),
            OWSHTTPError.networkFailure(.genericTimeout),
            URLError(.timedOut),
            serviceFailure(500),
            serviceFailure(503),
            serviceFailure(599),
        ]
        for failure in failures {
            let db = makeInMemoryDB()
            let account = makeAccount()
            var requests = 0
            let manager = RegistrationIdMismatchManagerImpl(db: db, tsAccountManager: account) { _ in
                requests += 1
                throw failure
            }

            await manager.validateRegistrationIds()
            await manager.validateRegistrationIds()

            XCTAssertEqual(requests, 2, "An unavailable lookup must be attempted again.")
            XCTAssertNil(flag("haveRegistrationIdsBeenChecked", db: db))
            XCTAssertNil(flag("hasRecordedSuspectedIssue", db: db))
            XCTAssertEqual(account.aciRegistrationIdMock(), 11)
            XCTAssertEqual(account.pniRegistrationIdMock(), 22)
        }
    }

    func testPniFailureAfterAciSuccessKeepsJournalPendingAndNextManagerRetriesBothIds() async {
        let db = makeInMemoryDB()
        let account = makeAccount()
        let identifiers = LocalIdentifiers.forUnitTests
        account.registrationStateMock = { .registered(identifiers) }
        var requests: [ServiceId] = []
        let firstManager = RegistrationIdMismatchManagerImpl(db: db, tsAccountManager: account) { serviceId in
            requests.append(serviceId)
            if serviceId is Aci { return 11 }
            throw self.serviceFailure(503)
        }

        await firstManager.validateRegistrationIds()

        XCTAssertEqual(requests, [identifiers.aci, identifiers.pni!])
        XCTAssertNil(flag("haveRegistrationIdsBeenChecked", db: db))
        XCTAssertNil(flag("hasRecordedSuspectedIssue", db: db))
        XCTAssertEqual(account.aciRegistrationIdMock(), 11)
        XCTAssertEqual(account.pniRegistrationIdMock(), 22)

        // A new manager models a later startup reading the same durable journal.
        let nextManager = RegistrationIdMismatchManagerImpl(db: db, tsAccountManager: account) { serviceId in
            requests.append(serviceId)
            return serviceId is Aci ? 11 : 22
        }
        await nextManager.validateRegistrationIds()

        XCTAssertEqual(requests, [identifiers.aci, identifiers.pni!, identifiers.aci, identifiers.pni!])
        XCTAssertEqual(flag("haveRegistrationIdsBeenChecked", db: db), true)
        XCTAssertNil(flag("hasRecordedSuspectedIssue", db: db))
    }

    func testSuccessfulMismatchUsesOnlyReturnedIdsAndRecordsCompletion() async {
        let db = makeInMemoryDB()
        let account = makeAccount()
        var requests = 0
        let manager = RegistrationIdMismatchManagerImpl(db: db, tsAccountManager: account) { serviceId in
            requests += 1
            return serviceId is Aci ? 33 : 44
        }

        await manager.validateRegistrationIds()

        XCTAssertEqual(requests, 2)
        XCTAssertEqual(account.aciRegistrationIdMock(), 33)
        XCTAssertEqual(account.pniRegistrationIdMock(), 44)
        XCTAssertEqual(flag("hasRecordedSuspectedIssue", db: db), true)
        XCTAssertEqual(flag("haveRegistrationIdsBeenChecked", db: db), true)
    }

    func testMatchingIdsCompleteOnceWithoutRecordingMismatch() async {
        let db = makeInMemoryDB()
        let account = makeAccount()
        var requests = 0
        let manager = RegistrationIdMismatchManagerImpl(db: db, tsAccountManager: account) { serviceId in
            requests += 1
            return serviceId is Aci ? 11 : 22
        }
        await manager.validateRegistrationIds()
        let nextManager = RegistrationIdMismatchManagerImpl(db: db, tsAccountManager: account) { _ in
            XCTFail("The completed journal must prevent another lookup.")
            throw BConnectedTransportError.unavailable(.unauthenticatedChat)
        }
        await nextManager.validateRegistrationIds()

        XCTAssertEqual(requests, 2)
        XCTAssertEqual(flag("haveRegistrationIdsBeenChecked", db: db), true)
        XCTAssertNil(flag("hasRecordedSuspectedIssue", db: db))
        XCTAssertEqual(account.aciRegistrationIdMock(), 11)
        XCTAssertEqual(account.pniRegistrationIdMock(), 22)
    }

    private func makeInMemoryDB() -> InMemoryDB {
        let originalContext = CurrentAppContext()
        SetCurrentAppContext(TestAppContext(), isRunningTests: true)
        defer { SetCurrentAppContext(originalContext, isRunningTests: true) }
        return InMemoryDB()
    }

    private func makeAccount() -> MockTSAccountManager {
        let account = MockTSAccountManager()
        account.aciRegistrationIdMock = { 11 }
        account.pniRegistrationIdMock = { 22 }
        return account
    }

    private func flag(_ key: String, db: InMemoryDB) -> Bool? {
        db.read { kvStore.fetchValue(Bool.self, forKey: key, tx: $0) }
    }

    private func serviceFailure(_ status: Int) -> OWSHTTPError {
        .serviceResponse(.init(
            requestUrl: URL(string: "https://example.invalid/v2/keys/test/1")!,
            responseStatus: status,
            responseHeaders: HttpHeaders(),
            responseData: nil,
        ))
    }
}
