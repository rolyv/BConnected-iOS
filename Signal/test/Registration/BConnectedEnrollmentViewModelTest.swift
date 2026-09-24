// Copyright 2026 BConnected contributors. SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import XCTest
import SwiftUI
import UIKit
#if !SWIFT_PACKAGE
@testable import Signal
#endif
@testable import SignalServiceKit

final class BConnectedEnrollmentViewModelTest: XCTestCase {
    @MainActor
    func testDeferredAndInvalidConfigurationsNeverConstructServices() {
        for initial in [false, true] {
            let model = BConnectedEnrollmentViewModel(info: [:], initialRegistration: initial,
                makeCoordinator: { _ in fatalError("Invalid config must not construct services") })
            model.setActive(true); model.submitDetails(); model.continueSetup(); model.sendCode(); model.verifyCode()
            XCTAssertEqual(model.screen, .help)
            XCTAssertFalse(model.busy)
            XCTAssertNil(model.progress)
        }
    }

    @MainActor
    func testApprovedReturnAutomaticallyCompletesWithoutSMS() async {
        let (model, community, account) = fixture()
        var completions = 0
        let completeModel = BConnectedEnrollmentViewModel(community: community, coordinator: account, makePreparation: preparation) { completions += 1 }
        completeModel.setActive(true); await settle(completeModel)
        XCTAssertEqual(completeModel.screen, .ready)
        XCTAssertEqual(completions, 1)
        XCTAssertEqual(community.sends, 0)
        XCTAssertEqual(account.calls, ["begin", "complete", "install", "local", "entropy", "profile:false", "keys", "finish"])
        completeModel.resume(); await settle(completeModel)
        XCTAssertEqual(completions, 1)
        XCTAssertEqual(model.screen, .returning)
    }

    @MainActor
    func testFirstSignupFromDraftUsesOneSMSAndAutomaticallyOpensInboxAfterVerification() async {
        await assertFirstSignup(approvalRequiresReturn: false)
    }

    @MainActor
    func testNewPendingSignupResumesOnFreshForegroundApprovalWithoutAnotherSMS() async {
        await assertFirstSignup(approvalRequiresReturn: true)
    }

    @MainActor
    func testPendingAndDeclinedUseFreshServerDecision() async {
        for status: BConnectedCommunityMember.Status in [.pending, .rejected, .suspended] {
            let (model, community, account) = fixture()
            community.freshStatus = status
            model.setActive(true); await settle(model)
            XCTAssertEqual(model.screen, status == .pending ? .pending : status == .rejected ? .declined : .accessPaused)
            XCTAssertTrue(account.calls.isEmpty)
            XCTAssertEqual(community.sends, 0)
        }
    }

    @MainActor
    func testPendingApprovalResumesOnForegroundWithoutSecondText() async {
        let (model, community, _) = fixture()
        community.freshStatus = .pending
        model.setActive(true); await settle(model)
        XCTAssertEqual(model.screen, .pending)
        model.setActive(false); community.freshStatus = .approved
        model.setActive(true); await settle(model)
        XCTAssertEqual(model.screen, .ready)
        XCTAssertEqual(community.sends, 0)
    }

    @MainActor
    func testMissingPhoneProofStopsWithoutLegacySendOrCompletion() async {
        let (model, community, account) = fixture()
        account.phoneProof = false
        model.setActive(true); await settle(model)
        XCTAssertEqual(model.screen, .help)
        XCTAssertEqual(account.calls, ["begin"])
        XCTAssertEqual(community.sends, 0)
    }

    @MainActor
    func testUncertainProfileRequiresExplicitContinuationAndFreshReads() async {
        let (model, community, account) = fixture()
        account.uncertainProfile = true
        model.setActive(true); await settle(model)
        XCTAssertEqual(model.screen, .continuation)
        XCTAssertFalse(account.calls.contains("profile:true"))
        let reads = community.approvalReads
        model.continueSetup(); await settle(model)
        XCTAssertGreaterThan(community.approvalReads, reads)
        XCTAssertTrue(account.calls.contains("status"))
        XCTAssertTrue(account.calls.contains("profile:true"))
        XCTAssertEqual(model.screen, .ready)
    }

    @MainActor
    func testFinalReadbackFailureNeverOpensInbox() async {
        let (model, _, account) = fixture()
        account.failCompletion = true
        model.setActive(true); await settle(model)
        XCTAssertEqual(model.screen, .continuation)
        XCTAssertTrue(account.calls.contains("finish"))
        XCTAssertNotEqual(model.screen, .ready)
    }

    @MainActor
    func testLegacyPreKeysRemainBlocked() async {
        let (model, _, account) = fixture()
        account.blockedKeys = true
        model.setActive(true); await settle(model)
        XCTAssertEqual(model.screen, .help)
        XCTAssertFalse(account.calls.contains("keys"))
        XCTAssertFalse(account.calls.contains("finish"))
    }

    @MainActor
    func testIntentTimerDoesNotAuthorizeRetry() async {
        let (model, community, account) = fixture()
        community.intentWait = Date().addingTimeInterval(-10)
        model.setActive(true); await settle(model)
        XCTAssertEqual(model.screen, .continuation)
        XCTAssertTrue(account.calls.isEmpty)
        model.tick(Date().addingTimeInterval(500)); await settle(model)
        XCTAssertEqual(community.intentRetries, [])
        model.continueSetup(); await settle(model)
        XCTAssertEqual(community.intentRetries, [true])
        XCTAssertEqual(model.screen, .ready)
    }

    @MainActor
    func testOfflineAndBackgroundNeverScheduleSMSOrKeepCode() async {
        let (model, community, account) = fixture()
        model.setOnline(false); model.setActive(true); model.continueSetup(); await settle(model)
        XCTAssertTrue(account.calls.isEmpty)
        XCTAssertEqual(community.sends, 0)
        model.code = "123456"; model.setActive(false)
        XCTAssertEqual(model.code, "")
    }

    @MainActor
    func testOfflineThenReconnectCancelsPendingExplicitSendEvenIfReadReturnsLater() async {
        let (model, community, _) = fixture(member: false)
        community.verified = false
        model.setActive(true); await settle(model)
        XCTAssertTrue(model.canSend)
        var releaseRead: CheckedContinuation<Void, Never>?
        community.beforePhoneRefresh = {
            community.beforePhoneRefresh = nil
            await withCheckedContinuation { releaseRead = $0 }
        }
        model.sendCode()
        for _ in 0..<500 { if releaseRead != nil { break }; await Task.yield() }
        XCTAssertNotNil(releaseRead)
        model.setOnline(false); model.setOnline(true)
        releaseRead?.resume()
        await settle(model)
        XCTAssertEqual(community.sends, 0)
        XCTAssertEqual(model.screen, .verifying)
        XCTAssertGreaterThanOrEqual(community.phoneReads, 3)
        model.sendCode(); await settle(model)
        XCTAssertEqual(community.sends, 1)
    }

    @MainActor
    func testExplicitCodeActionGetsFreshBoundedPollingBudget() async {
        let (model, community, _) = fixture(member: false)
        community.verified = false; community.smsSeconds = 30
        model.setActive(true); await settle(model)
        for _ in 0..<5 { model.tick(Date().addingTimeInterval(1000)); await settle(model) }
        let exhaustedReads = community.phoneReads
        model.tick(Date().addingTimeInterval(1000)); await settle(model)
        XCTAssertEqual(community.phoneReads, exhaustedReads)
        community.checkError = .rejected(.rateLimited, retryAfterSeconds: nil)
        model.code = "123456"; model.verifyCode(); await settle(model)
        let actionReads = community.phoneReads
        XCTAssertGreaterThan(actionReads, exhaustedReads)
        model.tick(Date().addingTimeInterval(1000)); await settle(model)
        XCTAssertGreaterThan(community.phoneReads, actionReads)
        XCTAssertEqual(community.sends, 0)
    }

    @MainActor
    func testStatusRetryAfterIsHonoredAcrossForegroundAndClockTicks() async {
        let (model, community, _) = fixture(member: false)
        community.verified = false
        model.setActive(true); await settle(model)
        community.beforePhoneRefresh = { throw BConnectedEnrollmentError.rejected(.rateLimited, retryAfterSeconds: 60) }
        model.code = "123456"; model.verifyCode(); await settle(model)
        let reads = community.phoneReads
        XCTAssertFalse(model.canCheck)
        XCTAssertFalse(model.canContinue)
        model.tick(Date().addingTimeInterval(5)); await settle(model)
        model.setActive(false); model.setActive(true); await settle(model)
        XCTAssertEqual(community.phoneReads, reads)
        XCTAssertEqual(community.sends, 0)
    }

    @MainActor
    func testMembershipLookupFailureKeepsVerifiedPhoneInResolution() async {
        for error in [BConnectedEnrollmentError.unavailable, .rejected(.rateLimited, retryAfterSeconds: 60)] {
            let (model, community, account) = fixture(member: false)
            community.verified = true
            community.beforePhoneRefresh = { throw error }
            model.setActive(true); await settle(model)
            XCTAssertEqual(model.screen, .resolvingMembership)
            XCTAssertFalse(model.canCheck); XCTAssertFalse(model.canSend)
            XCTAssertEqual(community.sends, 0)
            XCTAssertTrue(account.calls.isEmpty)
        }
    }

    @MainActor
    func testExpiredCodeRequiresFreshEligibilityAndExplicitNewSend() async {
        let (model, community, _) = fixture(member: false)
        community.verified = false
        model.setActive(true); await settle(model)
        community.checkError = .rejected(.codeExpired, retryAfterSeconds: nil)
        model.code = "123456"; model.verifyCode(); await settle(model)
        XCTAssertTrue(model.codeExpired)
        XCTAssertEqual(model.errors[.code], "That code has expired. Request a new one.")
        XCTAssertFalse(model.canCheck); XCTAssertFalse(model.canSend)
        XCTAssertEqual(community.sends, 0)
        community.smsSeconds = nil
        model.tick(Date().addingTimeInterval(1000)); await settle(model)
        XCTAssertFalse(model.canSend)
        community.smsSeconds = 0
        model.tick(Date().addingTimeInterval(1000)); await settle(model)
        XCTAssertTrue(model.canSend)
        XCTAssertEqual(community.sends, 0)
        model.sendCode(); await settle(model)
        XCTAssertEqual(community.sends, 1)
        XCTAssertFalse(model.codeExpired)
        XCTAssertNil(model.errors[.code])
    }

    @MainActor
    func testUnknownCooldownRemainsUnknownAndReturnDoesNotSend() async {
        let (model, community, _) = fixture(member: false)
        community.verified = false; community.smsSeconds = nil; community.checkSeconds = nil
        model.setActive(true); await settle(model)
        XCTAssertEqual(model.screen, .verifying)
        XCTAssertNil(model.smsWait); XCTAssertNil(model.checkWait)
        XCTAssertFalse(model.canSend); XCTAssertFalse(model.canCheck)
        model.tick(Date().addingTimeInterval(1000)); await settle(model)
        XCTAssertEqual(community.sends, 0)
        XCTAssertFalse(model.canSend)
    }

    @MainActor
    func testClockExpiryOnlyRefreshesEligibility() async {
        let (model, community, _) = fixture(member: false)
        community.verified = false; community.smsSeconds = 30
        model.setActive(true); await settle(model)
        model.tick(Date().addingTimeInterval(35)); await settle(model)
        XCTAssertFalse(model.canSend)
        XCTAssertEqual(community.sends, 0)
        XCTAssertGreaterThan(community.phoneReads, 1)
    }

    @MainActor
    func testCorruptJournalHasNoSavedProgressClaimOrEffects() {
        let community = Community(), account = Account()
        community.unreadable = true
        let model = BConnectedEnrollmentViewModel(community: community, coordinator: account, makePreparation: preparation)
        model.setActive(true)
        XCTAssertTrue(model.stateUnreadable)
        XCTAssertEqual(model.screen, .help)
        XCTAssertTrue(account.calls.isEmpty)
    }

    @MainActor
    func testNativePhoneFieldInternationalPasteReplacesSelectionAndUpdatesRegion() {
        var text = "(305) 555-0123", region = "US"
        let bridge = SignupPhoneField(text: Binding(get: { text }, set: { text = $0 }), region: Binding(get: { region }, set: { region = $0 }),
            wantsFocus: false, onFocus: {}, onBlur: {}, onNext: {})
        let delegate = bridge.makeCoordinator(), field = UITextField()
        field.text = text
        XCTAssertFalse(delegate.textField(field, shouldChangeCharactersIn: NSRange(location: 2, length: 2), replacementString: "+44 7700 900123"))
        XCTAssertEqual(region, "GB")
        XCTAssertEqual(text, "07700 900123")
        XCTAssertEqual(field.text, text)
        XCTAssertFalse(delegate.textField(field, shouldChangeCharactersIn: NSRange(location: 0, length: text.utf16.count), replacementString: ""))
        XCTAssertEqual(text, "")
        XCTAssertEqual(region, "GB")
    }

    @MainActor
    func testNativePhoneFieldTypedInternationalNumberUpdatesCountryBeforeFormatting() {
        for (input, startingRegion, expectedRegion, expectedText) in [
            ("+13055550123", "GB", "US", "(305) 555-0123"),
            ("+447700900123", "US", "GB", "07700 900123")
        ] {
            var text = "", region = startingRegion
            let bridge = SignupPhoneField(text: Binding(get: { text }, set: { text = $0 }), region: Binding(get: { region }, set: { region = $0 }),
                wantsFocus: false, onFocus: {}, onBlur: {}, onNext: {})
            let delegate = bridge.makeCoordinator(), field = UITextField()
            for character in input {
                XCTAssertFalse(delegate.textField(field, shouldChangeCharactersIn: NSRange(location: text.utf16.count, length: 0), replacementString: String(character)))
            }
            XCTAssertEqual(region, expectedRegion)
            XCTAssertEqual(text, expectedText)
        }
    }

    @MainActor
    func testNativePhoneFieldCompositionCommitNormalizesDigitsAndPreservesSelection() {
        var text = "", region = "US"
        let bridge = SignupPhoneField(text: Binding(get: { text }, set: { text = $0 }), region: Binding(get: { region }, set: { region = $0 }),
            wantsFocus: false, onFocus: {}, onBlur: {}, onNext: {})
        let delegate = bridge.makeCoordinator(), field = UITextField()
        field.text = "٣٠٥٥٥٥٠١٢٣"
        field.selectedTextRange = field.textRange(from: field.position(from: field.beginningOfDocument, offset: 3)!,
            to: field.position(from: field.beginningOfDocument, offset: 6)!)
        delegate.compositionChanged(field)
        XCTAssertEqual(text, "(305) 555-0123")
        XCTAssertEqual(field.offset(from: field.beginningOfDocument, to: field.selectedTextRange!.start), 6)
        XCTAssertEqual(field.offset(from: field.beginningOfDocument, to: field.selectedTextRange!.end), 10)
        field.text = "+44 7700 900123"
        delegate.compositionChanged(field)
        XCTAssertEqual(region, "GB")
        XCTAssertEqual(text, "07700 900123")
    }

    @MainActor
    func testNativePhoneFieldDoesNotRewriteMarkedComposition() {
        final class MarkedRange: UITextRange {}
        final class ComposingField: UITextField {
            override var markedTextRange: UITextRange? { MarkedRange() }
        }
        var text = "saved", region = "US"
        let bridge = SignupPhoneField(text: Binding(get: { text }, set: { text = $0 }), region: Binding(get: { region }, set: { region = $0 }),
            wantsFocus: false, onFocus: {}, onBlur: {}, onNext: {})
        let delegate = bridge.makeCoordinator(), field = ComposingField()
        field.text = "１２３"
        delegate.compositionChanged(field)
        XCTAssertEqual(field.text, "１２３")
        XCTAssertEqual(text, "saved")
        XCTAssertTrue(delegate.textField(field, shouldChangeCharactersIn: NSRange(location: 3, length: 0), replacementString: "４"))
        XCTAssertEqual(text, "saved")
    }

    @MainActor
    func testNativePhoneFieldPreservesOversizedUnsupportedPasteWithoutFormattingIt() {
        var text = "", region = "US"
        let bridge = SignupPhoneField(text: Binding(get: { text }, set: { text = $0 }), region: Binding(get: { region }, set: { region = $0 }),
            wantsFocus: false, onFocus: {}, onBlur: {}, onNext: {})
        let delegate = bridge.makeCoordinator(), field = UITextField()
        for pasted in [String(repeating: "3", count: 10_000), String(repeating: "unsupported ", count: 1_000)] {
            field.text = ""
            XCTAssertFalse(delegate.textField(field, shouldChangeCharactersIn: NSRange(location: 0, length: 0), replacementString: pasted))
            XCTAssertEqual(text, pasted)
            XCTAssertEqual(field.text, pasted)
        }
    }

    func testPhoneCaretMappingPreservesMiddleEditsAndInternationalPrefixRemoval() {
        XCTAssertEqual(BConnectedPhoneEntry.cursorOffset(from: "3059550123", offset: 4, to: "(305) 955-0123", preferRight: true), 7)
        XCTAssertEqual(BConnectedPhoneEntry.cursorOffset(from: "3055550123", offset: 3, to: "(305) 555-0123", preferRight: false), 4)
        XCTAssertEqual(BConnectedPhoneEntry.cursorOffset(from: "+44 7700 900123", offset: 14, to: "07700 900123", preferRight: true), 11)
        XCTAssertEqual(BConnectedPhoneEntry.cursorOffset(from: "", offset: 0, to: "", preferRight: false), 0)
    }

    func testLongUnsupportedPasteDoesNotUseQuadraticCaretMapping() {
        let pasted = String(repeating: "unsupported clipboard text ", count: 4000)
        let start = Date()
        XCTAssertEqual(BConnectedPhoneEntry.cursorOffset(from: pasted, offset: pasted.utf16.count, to: pasted, preferRight: true), pasted.utf16.count)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }

    func testCountryAwarePhoneParsingAndInternationalPaste() {
        let utility = PhoneNumberUtil()
        for input in ["3055550123", "1 305 555 0123", "+1 (305) 555-0123", "+١ (٣٠٥) ５５５-０１２３"] {
            XCTAssertEqual(BConnectedPhoneEntry.parse(input, region: "US", using: utility)?.e164, "+13055550123")
        }
        for (region, input, expected) in [("US", "+44 7700 900123", "+447700900123"), ("GB", "07700 900123", "+447700900123"),
            ("ES", "612 345 678", "+34612345678"), ("MX", "55 1234 5678", "+525512345678"), ("CA", "416 555 0123", "+14165550123")] {
            XCTAssertEqual(BConnectedPhoneEntry.parse(input, region: region, using: utility)?.e164, expected)
        }
        XCTAssertNil(BConnectedPhoneEntry.parse("3055550123 ext 9", region: "US", using: utility))
        XCTAssertNil(BConnectedPhoneEntry.parse("3055550123+", region: "US", using: utility))
        XCTAssertNil(BConnectedPhoneEntry.parse(String(repeating: "3", count: 100_000), region: "US", using: utility))
    }

    func testUnicodeDecimalNormalizationPreservesUnsupportedInput() {
        XCTAssertEqual(BConnectedPhoneEntry.normalized("+١ (٣٠٥) ５５５-０１２３"), "+1 (305) 555-0123")
        XCTAssertEqual(BConnectedPhoneEntry.normalized("3055550123 ext 9"), "3055550123 ext 9")
    }

    @MainActor private func fixture(member: Bool = true) -> (BConnectedEnrollmentViewModel, Community, Account) {
        let community = Community(), account = Account()
        community.hasMember = member
        let model = BConnectedEnrollmentViewModel(community: community, coordinator: account, makePreparation: preparation)
        return (model, community, account)
    }
    @MainActor private func assertFirstSignup(approvalRequiresReturn: Bool) async {
        let account = Account()
        account.hasRecord = false
        let community = FirstSignupCommunity(account: account)
        community.decision = approvalRequiresReturn ? .pending : .approved
        var completions = 0
        let model = BConnectedEnrollmentViewModel(community: community, coordinator: account, makePreparation: preparation) { completions += 1 }
        XCTAssertEqual(model.screen, .details)
        XCTAssertFalse(model.hasSavedSetup)
        XCTAssertNil(model.progress)
        XCTAssertEqual(model.phone, "305")
        XCTAssertEqual(model.name, "José Pérez")
        model.setActive(true); await settle(model)
        XCTAssertTrue(community.calls.isEmpty)
        model.phone = "(305) 555-0123"
        model.name = "  José Pérez  "
        model.saveDraft()
        XCTAssertEqual(community.savedDraft?.phone, "(305) 555-0123")
        model.submitDetails(); model.submitDetails(); await settle(model)
        XCTAssertEqual(model.screen, .verifying)
        XCTAssertEqual(community.application?.phone, "+13055550123")
        XCTAssertEqual(community.application?.name, "José Pérez")
        XCTAssertEqual(community.application?.year, 2008)
        XCTAssertNil(community.savedDraft)
        XCTAssertEqual(Array(community.calls.prefix(2)), ["apply", "send"])
        XCTAssertEqual(community.sends, 1)
        XCTAssertTrue(account.calls.isEmpty)
        XCTAssertEqual(completions, 0)

        model.code = "123456"
        await settle(model)
        XCTAssertTrue(community.checkedCodes.isEmpty)
        model.verifyCode(); model.verifyCode(); await settle(model)
        XCTAssertEqual(community.checkedCodes, ["123456"])
        XCTAssertEqual(model.code, "")
        if approvalRequiresReturn {
            XCTAssertEqual(model.screen, .pending)
            XCTAssertEqual(completions, 0)
            XCTAssertTrue(account.calls.isEmpty)
            model.setActive(false); model.setActive(true); await settle(model)
            XCTAssertEqual(model.screen, .pending)
            XCTAssertEqual(community.sends, 1)
            let previousApprovalReads = community.calls.filter { $0 == "approval" }.count
            model.setActive(false)
            community.decision = .approved
            model.setActive(true); await settle(model)
            XCTAssertGreaterThan(community.calls.filter { $0 == "approval" }.count, previousApprovalReads)
        }
        XCTAssertEqual(model.screen, .ready)
        XCTAssertEqual(completions, 1)
        XCTAssertEqual(community.sends, 1)
        XCTAssertEqual(community.preparedPhone, "+13055550123")
        XCTAssertEqual(account.calls, ["begin", "complete", "install", "local", "entropy", "profile:false", "keys", "finish"])
        if let approval = community.calls.firstIndex(of: "approval"), let binding = community.calls.firstIndex(of: "bind") {
            XCTAssertLessThan(approval, binding)
        } else { XCTFail("Setup must read approval before binding") }
        model.resume(); await settle(model)
        XCTAssertEqual(completions, 1)
        XCTAssertEqual(community.sends, 1)
    }
    @MainActor private func settle(_ model: BConnectedEnrollmentViewModel) async {
        for _ in 0..<500 { if !model.busy { return }; await Task.yield() }
        XCTFail("Driver did not settle")
    }
    @MainActor private func preparation(_ phone: String) async throws -> BConnectedEnrollmentPreparation {
        .init(phone: phone, unidentifiedAccessKey: Data(repeating: 1, count: 16), apnsToken: nil, discoverableByPhoneNumber: false, signalAgent: "test", userAgent: "test")
    }

    /// Models the empty-journal entry path; member/account material exists only after verification.
    @MainActor private final class FirstSignupCommunity: BConnectedSignupCommunity {
        let account: Account
        var savedDraft: BConnectedSignupDraft? = .init(phone: "305", region: "US", name: "José Pérez", year: "2008")
        var application: (name: String, year: Int, phone: String)?
        var decision: BConnectedCommunityMember.Status = .approved
        var member: BConnectedCommunityMember?
        var hasOperation = false, verified = false
        var calls: [String] = [], checkedCodes: [String] = []
        var sends = 0
        var preparedPhone: String?
        init(account: Account) { self.account = account }
        func progress() throws -> BConnectedCommunityProgress {
            .init(member: member, applicationOutcomeUncertain: false,
                savedApplicationPhone: application?.phone, savedApplicationName: application?.name, savedApplicationYear: application?.year,
                phoneSignup: application.map { _ in .init(hasChallenge: true, hasOperation: hasOperation, phoneVerified: verified,
                    smsOutcomeNeedsExplicitDecision: false, nextSmsSeconds: 0, nextCheckSeconds: hasOperation ? 0 : nil, observedAt: Date()) },
                canRestartPhoneSetup: false, intentOutcomeUncertain: false, intentRetryNotBefore: nil)
        }
        func draft() throws -> BConnectedSignupDraft? { savedDraft }
        func saveDraft(_ draft: BConnectedSignupDraft) throws { if application == nil { savedDraft = draft } }
        func applyPhone(name: String, year: Int, phone: String) async throws {
            guard application == nil else { throw BConnectedEnrollmentError.immutableConflict }
            calls.append("apply"); application = (name, year, phone); savedDraft = nil
        }
        func sendPhoneCode(explicitlyResendAfterUncertainOutcome: Bool, mayDispatch: () -> Bool) async throws {
            guard application != nil, !verified, mayDispatch() else { throw BConnectedEnrollmentError.operationRequired }
            calls.append("send"); sends += 1; hasOperation = true
        }
        func checkPhoneCode(_ code: String) async throws {
            guard hasOperation, !verified else { throw BConnectedEnrollmentError.operationRequired }
            calls.append("check"); checkedCodes.append(code); verified = true
        }
        func refreshPhoneVerification() async throws {
            calls.append("phone-status")
            if verified, let application {
                member = .init(id: "member", fullName: application.name, graduationYear: application.year, status: decision)
            }
        }
        func refreshApproval() async throws {
            guard verified, let member else { throw BConnectedEnrollmentError.approvalBindingRequired }
            calls.append("approval")
            self.member = .init(id: member.id, fullName: member.fullName, graduationYear: member.graduationYear, status: decision)
        }
        func connectApprovedMembership(preparation: () async throws -> BConnectedEnrollmentPreparation, explicitlyRetryLostIntent: Bool) async throws {
            guard verified, member?.status == .approved else { throw BConnectedEnrollmentError.approvalBindingRequired }
            calls.append("bind")
            let prepared = try await preparation()
            preparedPhone = prepared.phone; account.hasRecord = true
        }
    }

    @MainActor private final class Community: BConnectedSignupCommunity {
        var hasMember = true, verified = true, unreadable = false
        var status: BConnectedCommunityMember.Status = .approved
        var freshStatus: BConnectedCommunityMember.Status = .approved
        var smsSeconds: Int? = 0, checkSeconds: Int? = 0
        var sends = 0, approvalReads = 0, phoneReads = 0
        var intentWait: Date?
        var intentRetries: [Bool] = []
        var beforePhoneRefresh: (() async throws -> Void)?
        var checkError: BConnectedEnrollmentError?
        func progress() throws -> BConnectedCommunityProgress {
            if unreadable { throw BConnectedEnrollmentError.persistenceUnavailable }
            return .init(member: hasMember ? .init(id: "member", fullName: "José Pérez", graduationYear: 2008, status: status) : nil,
                applicationOutcomeUncertain: false, savedApplicationPhone: "+13055550123", savedApplicationName: "José Pérez", savedApplicationYear: 2008,
                phoneSignup: .init(hasChallenge: true, hasOperation: true, phoneVerified: verified, smsOutcomeNeedsExplicitDecision: false, nextSmsSeconds: smsSeconds, nextCheckSeconds: checkSeconds, observedAt: Date()),
                canRestartPhoneSetup: false, intentOutcomeUncertain: intentWait != nil, intentRetryNotBefore: intentWait)
        }
        func draft() throws -> BConnectedSignupDraft? { nil }
        func saveDraft(_ draft: BConnectedSignupDraft) throws {}
        func applyPhone(name: String, year: Int, phone: String) async throws {}
        func sendPhoneCode(explicitlyResendAfterUncertainOutcome: Bool, mayDispatch: () -> Bool) async throws { if mayDispatch() { sends += 1 } }
        func checkPhoneCode(_ code: String) async throws { if let checkError { throw checkError }; verified = true }
        func refreshPhoneVerification() async throws { phoneReads += 1; try await beforePhoneRefresh?() }
        func refreshApproval() async throws { approvalReads += 1; status = freshStatus }
        func connectApprovedMembership(preparation: () async throws -> BConnectedEnrollmentPreparation, explicitlyRetryLostIntent: Bool) async throws { intentRetries.append(explicitlyRetryLostIntent); intentWait = nil }
    }
    @MainActor private final class Account: BConnectedSignupAccount {
        var calls: [String] = []
        var hasRecord = true
        var phoneProof = true, installed = false, local = false, entropy = false, profile = false, keys = false
        var uncertainProfile = false, blockedKeys = false, failCompletion = false
        var observation: BConnectedEnrollmentObservation?
        func progress() throws -> BConnectedEnrollmentProgress? {
            guard hasRecord else { return nil }
            return .init(intent: .init(registrationAttemptId: "attempt", keyCommitment: "commitment"), hasApprovedIntentBinding: false,
                hasOperation: observation != nil, smsOutcomeNeedsExplicitDecision: false, lastObservation: observation,
                nativeAccountInstalled: installed, localAccountPrepared: local, accountEntropyPrepared: entropy,
                accountPublicationComplete: profile, accountPublicationNeedsExplicitRetry: uncertainProfile,
                preKeyPublicationComplete: keys, preKeyPublicationUncertain: false, preKeyPublicationBlocked: blockedKeys)
        }
        func perform(_ operation: BConnectedEnrollmentOperation, code: String?, explicitlyResendAfterUncertainOutcome: Bool) async throws -> BConnectedEnrollmentObservation {
            calls.append(operation.rawValue)
            let active = operation == .complete || observation?.state == .active
            let result = BConnectedEnrollmentObservation(operationId: "operation", state: active ? .active : .verification,
                registrationAuthorized: active, phoneVerified: phoneProof, nextSmsSeconds: 0, nextCheckSeconds: 0, expiresInSeconds: 600, account: nil)
            observation = result; return result
        }
        func installNativeAccount() async throws { calls.append("install"); installed = true }
        func prepareLocalAccount() throws { calls.append("local"); local = true }
        func prepareAccountEntropy() throws { calls.append("entropy"); entropy = true }
        func publishAccount(explicitlyRetryUncertainOutcome: Bool) async throws { calls.append("profile:\(explicitlyRetryUncertainOutcome)"); profile = true; uncertainProfile = false }
        func publishPreKeys() async throws { calls.append("keys"); keys = true }
        func completeDMAlpha() async throws { calls.append("finish"); if failCompletion { throw BConnectedEnrollmentError.unavailable } }
    }
}
