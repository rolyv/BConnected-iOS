// Copyright 2026 BConnected contributors. SPDX-License-Identifier: AGPL-3.0-only

import XCTest
@testable import SignalServiceKit

final class BConnectedStorageServiceManagerTest: XCTestCase {
    func testUnsupportedRestoreIsImmediatelyRejectedWithoutRegistrationContext() throws {
        let manager = makeUnavailableManager()

        // The reported crash used implicit authentication with no identifiers
        // installed in this manager. Rejection must precede any global account
        // lookup, and the returned promise must already be settled.
        let promise = manager.restoreOrCreateManifestIfNecessary(
            authedAccount: .implicit,
            masterKeySource: .implicit,
        )
        let result = try XCTUnwrap(promise.result)
        XCTAssertThrowsError(try result.get()) { error in
            XCTAssertEqual(error as? BConnectedTransportError, .unavailable(.storageService))
        }
    }

    func testUnsupportedRotationAndRestoreWaitRejectWithoutQueuing() async {
        let manager = makeUnavailableManager()
        let modes: [StorageServiceManager.ManifestRotationMode] = [.preservingRecordsIfPossible, .alsoRotatingRecords]
        for mode in modes {
            do {
                try await manager.rotateManifest(mode: mode, authedAccount: .implicit)
                XCTFail("An unsupported rotation must fail.")
            } catch {
                XCTAssertEqual(error as? BConnectedTransportError, .unavailable(.storageService))
            }
        }
        do {
            try await manager.waitForPendingRestores()
            XCTFail("An unavailable service cannot report a completed restore.")
        } catch {
            XCTAssertEqual(error as? BConnectedTransportError, .unavailable(.storageService))
        }
    }

    @MainActor
    func testUnsupportedCallbacksLeaveManagerIdleWithoutLifecycleRegistration() async throws {
        let readiness = RecordingReadiness()
        let manager = StorageServiceManagerImpl(appReadiness: readiness, transportCapabilities: .chatOnly)
        XCTAssertEqual(readiness.willBecomeReadyRegistrations, 0)
        XCTAssertEqual(readiness.didBecomeReadyRegistrations, 0)

        manager.recordPendingLocalAccountUpdates()
        manager.recordPendingUpdates(updatedRecipientUniqueIds: ["recipient-fixture"])
        manager.recordPendingUpdates(updatedStoryDistributionListIds: [Data([1])])
        manager.backupPendingChanges(authedAccount: .implicit)
        NotificationCenter.default.post(name: .OWSApplicationWillResignActive, object: nil)
        NotificationCenter.default.post(name: .OWSApplicationDidBecomeActive, object: nil)
        NotificationCenter.default.post(name: .backupPlanChanged, object: nil)

        // Installing local identifiers later must not enable an unsupported
        // service or release a previously queued operation or debounce timer.
        manager.setLocalIdentifiers(.forUnitTests)
        manager.backupPendingChanges(authedAccount: .implicit)
        try await manager.waitForSteadyState()
        XCTAssertEqual(readiness.willBecomeReadyRegistrations, 0)
        XCTAssertEqual(readiness.didBecomeReadyRegistrations, 0)
    }

    func testLocalResetStillClearsOnlyStorageServiceStateWhenTransportIsUnavailable() {
        let db = makeInMemoryDB()
        let manager = makeUnavailableManager()
        let storageState = KeyValueStore(collection: "kOWSStorageServiceOperation_IdentifierMap")
        let otherState = KeyValueStore(collection: "BConnectedStorageServiceManagerTest.OtherState")
        db.write { tx in
            storageState.setString("saved-storage-state", key: "fixture", transaction: tx)
            otherState.setString("preserved", key: "fixture", transaction: tx)
            manager.resetLocalData(transaction: tx)
        }
        db.read { tx in
            XCTAssertNil(storageState.getString("fixture", transaction: tx))
            XCTAssertEqual(otherState.getString("fixture", transaction: tx), "preserved")
        }
    }

    func testDefaultLegacyCapabilityStillRegistersLifecycleWork() {
        let originalContext = CurrentAppContext()
        SetCurrentAppContext(TestAppContext(), isRunningTests: true)
        defer { SetCurrentAppContext(originalContext, isRunningTests: true) }

        let readiness = RecordingReadiness()
        _ = StorageServiceManagerImpl(appReadiness: readiness)
        XCTAssertEqual(readiness.willBecomeReadyRegistrations, 1)
        XCTAssertEqual(readiness.didBecomeReadyRegistrations, 1)
    }

    private func makeUnavailableManager() -> StorageServiceManagerImpl {
        StorageServiceManagerImpl(appReadiness: AppReadinessMock(), transportCapabilities: .chatOnly)
    }

    private func makeInMemoryDB() -> InMemoryDB {
        let originalContext = CurrentAppContext()
        SetCurrentAppContext(TestAppContext(), isRunningTests: true)
        defer { SetCurrentAppContext(originalContext, isRunningTests: true) }
        return InMemoryDB()
    }

    private final class RecordingReadiness: AppReadinessMock {
        private(set) var willBecomeReadyRegistrations = 0
        private(set) var didBecomeReadyRegistrations = 0

        override func runNowOrWhenAppWillBecomeReady(
            _ block: @escaping @MainActor () -> Void,
            file: String,
            function: String,
            line: Int,
        ) {
            willBecomeReadyRegistrations += 1
        }

        override func runNowOrWhenAppDidBecomeReadySync(
            _ block: @escaping @MainActor () -> Void,
            file: String,
            function: String,
            line: Int,
        ) {
            didBecomeReadyRegistrations += 1
        }
    }
}
