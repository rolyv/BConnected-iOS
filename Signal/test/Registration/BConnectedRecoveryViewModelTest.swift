// Copyright 2026 BConnected contributors. SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import XCTest
@testable import Signal
@testable import SignalServiceKit

final class BConnectedRecoveryViewModelTest: XCTestCase {
    @MainActor
    func testBeginRequiresConsentAndOnlyPreparesAndReadsWithoutSMS() async {
        let service = RecoveryViewService()
        service.saved = false
        let model = fixture(service)
        model.setActive(true); model.phone = "+13055550123"
        model.begin(); await settle(model)
        XCTAssertEqual(service.preparations, 0)
        model.acceptedConsequences = true
        model.begin(); await settle(model)
        XCTAssertEqual(service.preparations, 1)
        XCTAssertEqual(service.reads, 1)
        XCTAssertEqual(service.sends, 0)
        XCTAssertTrue(model.canSend)
        XCTAssertTrue(model.hasSavedRecovery)
    }
    @MainActor
    func testRestoredRecoveryOnlyReadsAndNeverReplaysReplacementConsent() async {
        let service = RecoveryViewService(); service.state = .authorized
        let model = fixture(service)
        model.setActive(true); await settle(model)
        XCTAssertEqual(service.reads, 1)
        XCTAssertFalse(model.canReplace)
        model.replaceAccount(); await settle(model)
        XCTAssertEqual(service.replacements, 0)
        model.setActive(false); model.setActive(true); await settle(model)
        XCTAssertEqual(service.reads, 2)
        XCTAssertEqual(service.sends, 0)
        XCTAssertEqual(service.replacements, 0)
    }
    @MainActor
    func testBackgroundRevokesReplacementWhileStatusIsInFlight() async {
        let service = RecoveryViewService(); service.state = .authorized
        let model = fixture(service)
        model.setActive(true); await settle(model)
        var release: CheckedContinuation<Void, Never>?
        service.beforeReplacement = { await withCheckedContinuation { release = $0 } }
        model.acceptedConsequences = true
        model.replaceAccount()
        for _ in 0..<500 { if release != nil { break }; await Task.yield() }
        XCTAssertNotNil(release)
        model.setActive(false); model.setActive(true)
        release?.resume(); await settle(model)
        XCTAssertEqual(service.replacements, 0)
        XCTAssertFalse(model.acceptedConsequences)
        XCTAssertEqual(service.sends, 0)
        XCTAssertGreaterThan(service.reads, 1)
    }
    @MainActor
    func testUnknownAndElapsedCooldownDoNotAuthorizeSMSWithoutFreshResponse() async {
        let service = RecoveryViewService(); service.smsSeconds = 60
        let model = fixture(service)
        model.setActive(true); await settle(model)
        model.tick(Date().addingTimeInterval(1000))
        XCTAssertFalse(model.canSend)
        model.sendCode(); await settle(model)
        XCTAssertEqual(service.sends, 0)
        service.smsSeconds = nil; model.refresh(); await settle(model)
        XCTAssertFalse(model.canSend)
        service.smsSeconds = 0; model.refresh(); await settle(model)
        XCTAssertTrue(model.canSend)
        model.sendCode(); await settle(model)
        XCTAssertEqual(service.sends, 1)
    }
    @MainActor
    func testStatusFailureKeepsManualRetryAvailableAndPreservesRecovery() async {
        let service = RecoveryViewService(); service.failure = .unavailable
        let model = fixture(service)
        model.setActive(true); await settle(model)
        XCTAssertTrue(model.hasSavedRecovery)
        XCTAssertTrue(model.canAct)
        XCTAssertFalse(model.canSend); XCTAssertFalse(model.canCheck)
        service.failure = nil
        model.refresh(); await settle(model)
        XCTAssertTrue(model.canSend); XCTAssertTrue(model.canCheck)
        XCTAssertEqual(service.sends, 0); XCTAssertEqual(service.replacements, 0)
    }
    @MainActor
    func testActiveRecoveryFinishesNativeSetupBeforeOpeningInbox() async {
        let service = RecoveryViewService(); service.state = .active
        var completions = 0
        let model = fixture(service) { completions += 1 }
        model.setActive(true); await settle(model)
        XCTAssertEqual(service.finishes, [false])
        XCTAssertTrue(model.ready)
        XCTAssertEqual(completions, 1)
        XCTAssertEqual(service.sends, 0); XCTAssertEqual(service.replacements, 0)
    }
    @MainActor
    func testUncertainPublicationNeedsExplicitContinuationAndNeverRepeatsReplacement() async {
        let service = RecoveryViewService(); service.state = .active; service.failPublication = true
        var completions = 0
        let model = fixture(service) { completions += 1 }
        model.setActive(true); await settle(model)
        XCTAssertFalse(model.ready); XCTAssertEqual(completions, 0)
        model.continueSetup(); await settle(model)
        XCTAssertEqual(service.finishes, [false, true])
        XCTAssertTrue(model.ready); XCTAssertEqual(completions, 1)
        XCTAssertEqual(service.replacements, 0); XCTAssertEqual(service.sends, 0)
    }
    @MainActor
    func testRetryAfterSurvivesForegroundAndBlocksManualActions() async {
        let service = RecoveryViewService(); service.failure = .rejected(.temporarilyUnavailable, retryAfterSeconds: 60)
        let model = fixture(service)
        model.setActive(true); await settle(model)
        let reads = service.reads
        XCTAssertFalse(model.canAct)
        model.setActive(false); model.setActive(true); await settle(model)
        model.refresh(); await settle(model)
        XCTAssertEqual(service.reads, reads)
        XCTAssertEqual(service.sends, 0)
    }
    @MainActor private func fixture(_ service: RecoveryViewService, completion: @escaping () -> Void = {}) -> BConnectedRecoveryViewModel {
        .init(service: service, preparation: { phone in
            .init(phone: phone, unidentifiedAccessKey: Data(repeating: 1, count: 16), apnsToken: nil,
                  discoverableByPhoneNumber: false, signalAgent: "BConnected-iOS", userAgent: "Signal-iOS/8.30.0.8")
        }, onCompleted: completion)
    }
    @MainActor private func settle(_ model: BConnectedRecoveryViewModel) async {
        for _ in 0..<500 { if !model.busy { return }; await Task.yield() }
        XCTFail("Recovery did not settle")
    }
}

@MainActor
private final class RecoveryViewService: BConnectedRecoveryServing {
    var saved = true
    var state: BConnectedRecoveryObservation.State = .verification
    var smsSeconds: Int? = 0
    var preparations = 0, reads = 0, sends = 0, checks = 0, replacements = 0
    var finishes: [Bool] = []
    var failPublication = false
    var failure: BConnectedEnrollmentError?
    var beforeReplacement: (() async -> Void)?
    func progress() throws -> BConnectedRecoveryProgress? {
        guard saved else { return nil }
        let identified = [.authorized, .recovering, .active].contains(state)
        let observation = BConnectedRecoveryObservation(recoveryId: "00000000-0000-4000-8000-000000000010", state: state,
            phoneVerified: state != .verification, nextSmsSeconds: state == .verification ? smsSeconds : nil,
            nextCheckSeconds: state == .verification ? 0 : nil, expiresInSeconds: 300, registrationAuthorized: state == .active,
            memberId: identified ? "00000000-0000-4000-8000-000000000002" : nil,
            account: identified ? .init(aci: "00000000-0000-4000-8000-000000000003", pni: "00000000-0000-4000-8000-000000000004", number: "+13055550123", deviceId: 1) : nil,
            fullName: identified ? "José Pérez" : nil, graduationYear: identified ? 2008 : nil)
        return .init(phone: "+13055550123", recoveryAttemptId: "frozen-attempt", observation: observation,
            observedAt: Date(), sendOutcomeUncertain: false, replacementDispatched: state == .active || state == .recovering)
    }
    func prepare(_ input: BConnectedEnrollmentPreparation) throws { preparations += 1; saved = true }
    func refresh() async throws { reads += 1; if let failure { throw failure } }
    func sendCode(confirmedUncertain: Bool, mayDispatch: () -> Bool) async throws { if mayDispatch() { sends += 1 } }
    func checkCode(_ code: String) async throws { checks += 1; state = .awaitingAuthorization }
    func replaceAccount(mayDispatch: () -> Bool) async throws {
        await beforeReplacement?()
        try Task.checkCancellation()
        if mayDispatch() { replacements += 1; state = .active }
    }
    func finishLocalSetup(explicitRetry: Bool) async throws {
        finishes.append(explicitRetry)
        if failPublication && !explicitRetry { throw BConnectedEnrollmentError.explicitPublicationRetryRequired }
    }
}
