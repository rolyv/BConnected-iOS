// Copyright 2026 BConnected contributors. SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import XCTest
import GRDB
@testable import SignalServiceKit

final class BConnectedRecoveryTest: XCTestCase, @unchecked Sendable {
    private let endpoint = try! BConnectedEnrollmentEndpoint(origin: URL(string: "https://recovery.example.invalid")!)
    private func input() -> BConnectedEnrollmentPreparation {
        .init(phone: "+13055550123", unidentifiedAccessKey: Data(repeating: 1, count: 16), apnsToken: nil,
              discoverableByPhoneNumber: false, signalAgent: "BConnected-iOS", userAgent: "Signal-iOS/8.30.0.8")
    }
    @MainActor private func fixture() throws -> (BConnectedRecoveryCoordinator, RecoveryMemory, RecoverySender) {
        let store = RecoveryMemory(), sender = RecoverySender()
        let native = BConnectedEnrollmentCoordinator(persistence: RecoveryUnusedNative(), client: RecoveryUnusedNative())
        let service = BConnectedRecoveryCoordinator(endpoint: endpoint, persistence: store, client: sender, native: native)
        try service.prepare(input())
        return (service, store, sender)
    }
    @MainActor
    func testRestartReusesExactNewMaterialAndStatusNeverSends() async throws {
        let (service, store, sender) = try fixture()
        let bytes = try BConnectedRecoveryWire.encoded(XCTUnwrap(store.material))
        try await service.refresh()
        let restarted = BConnectedRecoveryCoordinator(endpoint: endpoint, persistence: store, client: sender,
            native: BConnectedEnrollmentCoordinator(persistence: RecoveryUnusedNative(), client: RecoveryUnusedNative()))
        try restarted.prepare(input()); try await restarted.refresh()
        XCTAssertEqual(try BConnectedRecoveryWire.encoded(XCTUnwrap(store.material)), bytes)
        XCTAssertEqual(sender.operations, [.begin, .status])
        XCTAssertEqual(try restarted.progress()?.observation?.state, .verification)
    }
    @MainActor
    func testLostSMSRetainsMarkerAndRequiresExplicitResend() async throws {
        let (service, store, sender) = try fixture()
        sender.failure = .sendCode
        do { try await service.sendCode(confirmedUncertain: false, mayDispatch: { true }); XCTFail() } catch {}
        XCTAssertTrue(try XCTUnwrap(service.progress()).sendOutcomeUncertain)
        let material = try BConnectedRecoveryWire.encoded(XCTUnwrap(store.material))
        sender.failure = nil
        try await service.refresh()
        do { try await service.sendCode(confirmedUncertain: false, mayDispatch: { true }); XCTFail() }
        catch { XCTAssertEqual(error as? BConnectedEnrollmentError, .explicitSendRequired) }
        XCTAssertEqual(sender.operations.filter { $0 == .sendCode }.count, 1)
        try await service.sendCode(confirmedUncertain: true, mayDispatch: { true })
        XCTAssertFalse(try XCTUnwrap(service.progress()).sendOutcomeUncertain)
        XCTAssertEqual(try BConnectedRecoveryWire.encoded(XCTUnwrap(store.material)), material)
    }
    @MainActor
    func testStatusAndUnapprovedCompleteNeverStartReplacement() async throws {
        let (service, store, sender) = try fixture()
        sender.state = .awaitingAuthorization
        try await service.refresh()
        do { try await service.replaceAccount(mayDispatch: { true }); XCTFail() } catch {}
        XCTAssertFalse(try XCTUnwrap(service.progress()).replacementDispatched)
        XCTAssertEqual(store.preflights, 1)
        XCTAssertFalse(sender.operations.contains(.complete))
    }
    @MainActor
    func testPreflightConflictStopsBeforeReplacementAndPreservesFrozenKeys() async throws {
        let (service, store, sender) = try fixture()
        sender.state = .authorized
        try await service.refresh()
        let original = try BConnectedRecoveryWire.encoded(XCTUnwrap(store.material))
        store.rejectPreflight = true
        do { try await service.replaceAccount(mayDispatch: { true }); XCTFail() }
        catch { XCTAssertEqual(error as? BConnectedEnrollmentError, .immutableConflict) }
        XCTAssertFalse(sender.operations.contains(.complete))
        XCTAssertFalse(try XCTUnwrap(service.progress()).replacementDispatched)
        XCTAssertEqual(try BConnectedRecoveryWire.encoded(XCTUnwrap(store.material)), original)
    }
    @MainActor
    func testLostReplacementReplyReconcilesSameAccountWithoutCompletingAgain() async throws {
        let (service, store, sender) = try fixture()
        sender.state = .authorized; try await service.refresh()
        let expectedAccount = try XCTUnwrap(service.progress()?.observation?.account)
        sender.failure = .complete
        do { try await service.replaceAccount(mayDispatch: { true }); XCTFail() } catch {}
        XCTAssertTrue(try XCTUnwrap(service.progress()).replacementDispatched)
        sender.failure = nil; sender.state = .active
        let restarted = BConnectedRecoveryCoordinator(endpoint: endpoint, persistence: store, client: sender,
            native: BConnectedEnrollmentCoordinator(persistence: RecoveryUnusedNative(), client: RecoveryUnusedNative()))
        try await restarted.refresh()
        XCTAssertEqual(try restarted.progress()?.observation?.account, expectedAccount)
        XCTAssertEqual(sender.operations.filter { $0 == .complete }.count, 1)
        XCTAssertNil(store.material?.installedAccount)
    }
    @MainActor
    func testChangedAuthorizedAccountAndUnsolicitedActiveAreRejected() async throws {
        let (service, store, sender) = try fixture()
        sender.state = .authorized; try await service.refresh()
        let old = try BConnectedRecoveryWire.encoded(XCTUnwrap(store.material))
        sender.aci = "00000000-0000-4000-8000-000000000099"
        do { try await service.refresh(); XCTFail() } catch {}
        XCTAssertEqual(try BConnectedRecoveryWire.encoded(XCTUnwrap(store.material)), old)
        XCTAssertEqual(try service.progress()?.observation?.state, .authorized)
        let (unsolicited, _, untrustedSender) = try fixture()
        untrustedSender.state = .active
        do { try await unsolicited.refresh(); XCTFail() } catch {}
        XCTAssertNil(try unsolicited.progress()?.observation)
    }
    @MainActor
    func testOperatorCompletionRequiresPreviouslyFrozenAuthorizationAndNeverDispatchesComplete() async throws {
        let (service, store, sender) = try fixture()
        sender.state = .authorized; try await service.refresh()
        let account = try XCTUnwrap(service.progress()?.observation?.account)
        sender.state = .recovering; try await service.refresh()
        sender.state = .active; try await service.refresh()
        XCTAssertEqual(try service.progress()?.observation?.account, account)
        XCTAssertTrue(try XCTUnwrap(store.journal).operatorCompletionObserved)
        XCTAssertFalse(try XCTUnwrap(store.journal).replacementDispatched)
        XCTAssertFalse(sender.operations.contains(.complete))
        XCTAssertFalse(sender.operations.contains(.sendCode))
        XCTAssertNil(store.material?.installedAccount)
        store.rejectPreflight = true
        do { try await service.finishLocalSetup(explicitRetry: false); XCTFail() }
        catch { XCTAssertEqual(error as? BConnectedEnrollmentError, .immutableConflict) }
    }
    @MainActor
    func testRequestUsesOwnedRecoveryRouteAndContainsOnlyFrozenPublicMaterial() throws {
        let (_, store, _) = try fixture()
        let material = try XCTUnwrap(store.material), journal = try XCTUnwrap(store.journal)
        let request = try BConnectedRecoveryClient(endpoint: endpoint).request(.begin, journal: journal, material: material, code: nil)
        XCTAssertEqual(request.url?.absoluteString, "https://recovery.example.invalid/v1/bconnected/recovery/begin")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic " + Data((material.phone + ":" + material.password).utf8).base64EncodedString())
        let body = try BConnectedEnrollmentWire.object(XCTUnwrap(request.httpBody))
        XCTAssertEqual(Set(body.keys), ["recoveryAttemptId", "registrationRequest", "originalSignalAgent", "originalUserAgent"])
        XCTAssertFalse(String(decoding: request.httpBody!, as: UTF8.self).contains(material.aci.pair.base64EncodedString()))
        XCTAssertFalse(String(describing: journal).contains(material.attempt))
    }
    func testWireRejectsWrongAccountAuthorityUnknownFieldsAndErrorStatus() throws {
        let response = RecoverySender.observation(state: .active)
        var object = try BConnectedEnrollmentWire.object(BConnectedRecoveryWire.encoded(response))
        // Codable omits nil fields; the wire contract requires explicit nulls.
        for key in ["nextSmsSeconds", "nextCheckSeconds"] { object[key] = NSNull() }
        let valid = try BConnectedEnrollmentWire.encode(object)
        XCTAssertEqual(try BConnectedRecoveryWire.response(valid, status: 200, expectedId: response.recoveryId, phone: "+13055550123"), response)
        for mutation in ["account", "registrationAuthorized", "unexpected", "recoveryId"] {
            var bad = object
            switch mutation {
            case "account": var account = bad["account"] as! [String: Any]; account["deviceId"] = 2; bad["account"] = account
            case "registrationAuthorized": bad[mutation] = false
            case "unexpected": bad[mutation] = true
            default: bad[mutation] = "00000000-0000-4000-8000-000000000099"
            }
            XCTAssertThrowsError(try BConnectedRecoveryWire.response(BConnectedEnrollmentWire.encode(bad), status: 200, expectedId: response.recoveryId, phone: "+13055550123"))
        }
        XCTAssertThrowsError(try BConnectedRecoveryWire.response(Data(#"{"code":"RECOVERY_NOT_AUTHORIZED"}"#.utf8), status: 503, expectedId: nil, phone: "+13055550123"))
        XCTAssertThrowsError(try BConnectedRecoveryWire.response(Data(#"{"code":"RECOVERY_NOT_AUTHORIZED"}"#.utf8), status: 403, expectedId: nil, phone: "+13055550123")) {
            XCTAssertEqual($0 as? BConnectedEnrollmentError, .rejected(.recoveryNotAuthorized, retryAfterSeconds: nil))
        }
    }
    func testRecoveryEnrollmentStorageCannotOverwriteOriginalJournals() throws {
        let originalContext = CurrentAppContext()
        SetCurrentAppContext(TestAppContext(), isRunningTests: true)
        let db = InMemoryDB()
        SetCurrentAppContext(originalContext, isRunningTests: true)
        let original = try BConnectedEnrollmentRecord.generate(input())
        let originalBytes = try BConnectedRecoveryWire.encoded(original)
        let communityBytes = Data("original community journal remains opaque".utf8)
        db.write { tx in
            KeyValueStore(collection: "BConnectedEnrollment.v1").setData(originalBytes, key: "attempt", transaction: tx)
            KeyValueStore(collection: "BConnectedCommunityEnrollment.v1").setData(communityBytes, key: "session", transaction: tx)
        }
        let store = BConnectedEnrollmentStore(db: db, journal: .recovery)
        var replacement = try BConnectedEnrollmentRecord.generate(input()); replacement.journal = .recovery
        try store.transaction { $0 = replacement }
        XCTAssertThrowsError(try store.transaction { $0 = original })
        XCTAssertEqual(try store.transaction { $0?.attempt }, replacement.attempt)
        db.read { tx in
            XCTAssertEqual(KeyValueStore(collection: "BConnectedEnrollment.v1").getData("attempt", transaction: tx), originalBytes)
            XCTAssertEqual(KeyValueStore(collection: "BConnectedCommunityEnrollment.v1").getData("session", transaction: tx), communityBytes)
        }
    }
    func testRecoveryRejectsExistingRatchetOrSenderKeyMetadataWithoutChangingIt() throws {
        let originalContext = CurrentAppContext()
        SetCurrentAppContext(TestAppContext(), isRunningTests: true)
        let db = InMemoryDB()
        SetCurrentAppContext(originalContext, isRunningTests: true)
        try db.writeWithRollbackIfThrows { tx in
            try BConnectedRecoveryStore.validateNoPriorSessions(tx: tx)
            let recipient = try SignalRecipient.insertRecord(tx: tx)
            try tx.database.execute(sql: "INSERT INTO Session (recipientId, localIdentity, deviceId, serializedRecord) VALUES (?, 0, 1, ?)",
                arguments: [recipient.id, Data([1, 2, 3])])
            XCTAssertThrowsError(try BConnectedRecoveryStore.validateNoPriorSessions(tx: tx))
            XCTAssertEqual(try Data.fetchOne(tx.database, sql: "SELECT serializedRecord FROM Session"), Data([1, 2, 3]))
            try tx.database.execute(sql: "DELETE FROM Session")
            try tx.database.execute(sql: "INSERT INTO SenderKey (ownerRecipientId, ownerDeviceId, distributionId, deletionType, insertedAt, serializedRecord) VALUES (?, 1, ?, 0, 1, ?)",
                arguments: [recipient.id, UUID(), Data([4, 5, 6])])
            XCTAssertThrowsError(try BConnectedRecoveryStore.validateNoPriorSessions(tx: tx))
            XCTAssertEqual(try Data.fetchOne(tx.database, sql: "SELECT serializedRecord FROM SenderKey"), Data([4, 5, 6]))
            try tx.database.execute(sql: "DELETE FROM SenderKey")
            // An orphan receipt is also a conflict. Defer the fixture FK check and remove
            // this intentionally incomplete row before committing the test transaction.
            try tx.database.execute(sql: "PRAGMA defer_foreign_keys = ON")
            try tx.database.execute(sql: "INSERT INTO SenderKeySentToDevice (senderKeyId, recipientId, deviceId, registrationId) VALUES (999, ?, 1, 123)", arguments: [recipient.id])
            XCTAssertThrowsError(try BConnectedRecoveryStore.validateNoPriorSessions(tx: tx))
            XCTAssertEqual(try Int.fetchOne(tx.database, sql: "SELECT COUNT(*) FROM SenderKeySentToDevice"), 1)
            try tx.database.execute(sql: "DELETE FROM SenderKeySentToDevice")
            try BConnectedRecoveryStore.validateNoPriorSessions(tx: tx)
        }
    }
}

private final class RecoveryMemory: BConnectedRecoveryPersistence {
    var journal: BConnectedRecoveryJournal?
    var material: BConnectedEnrollmentRecord?
    var preflights = 0
    var rejectPreflight = false
    func transaction<T>(_ action: (inout BConnectedRecoveryJournal?, inout BConnectedEnrollmentRecord?) throws -> T) throws -> T {
        var journal = self.journal, material = self.material
        let result = try action(&journal, &material)
        if let journal, let material { try journal.validate(material: material) }
        self.journal = journal; self.material = material
        return result
    }
    func validateLocalBeforeReplacement(material: BConnectedEnrollmentRecord, account: BConnectedEnrollmentObservation.Account?) throws {
        preflights += 1
        if rejectPreflight { throw BConnectedEnrollmentError.immutableConflict }
    }
}
private final class RecoverySender: BConnectedRecoverySending {
    static let originalACI = "00000000-0000-4000-8000-000000000001"
    var state: BConnectedRecoveryObservation.State = .verification
    var aci = originalACI
    var operations: [BConnectedRecoveryOperation] = []
    var failure: BConnectedRecoveryOperation?
    static func observation(state: BConnectedRecoveryObservation.State, aci: String = originalACI) -> BConnectedRecoveryObservation {
        let metadata = [.authorized, .recovering, .active].contains(state)
        return .init(recoveryId: "00000000-0000-4000-8000-000000000010", state: state,
            phoneVerified: state != .verification, nextSmsSeconds: state == .verification ? 0 : nil,
            nextCheckSeconds: state == .verification ? 0 : nil, expiresInSeconds: 300,
            registrationAuthorized: state == .active, memberId: metadata ? "00000000-0000-4000-8000-000000000002" : nil,
            account: metadata ? .init(aci: aci, pni: "00000000-0000-4000-8000-000000000003", number: "+13055550123", deviceId: 1) : nil,
            fullName: metadata ? "José Pérez" : nil, graduationYear: metadata ? 2008 : nil)
    }
    func send(_ operation: BConnectedRecoveryOperation, journal: BConnectedRecoveryJournal, material: BConnectedEnrollmentRecord, code: String?) async throws -> BConnectedRecoveryObservation {
        operations.append(operation)
        if failure == operation { throw BConnectedEnrollmentError.unavailable }
        return Self.observation(state: state, aci: aci)
    }
}
private final class RecoveryUnusedNative: BConnectedEnrollmentPersistence, BConnectedEnrollmentSending {
    func transaction<T>(_ update: (inout BConnectedEnrollmentRecord?) throws -> T) throws -> T {
        var record: BConnectedEnrollmentRecord?
        return try update(&record)
    }
    func send(_ operation: BConnectedEnrollmentOperation, record: BConnectedEnrollmentRecord, code: String?) async throws -> BConnectedEnrollmentObservation { throw BConnectedEnrollmentError.unavailable }
}
