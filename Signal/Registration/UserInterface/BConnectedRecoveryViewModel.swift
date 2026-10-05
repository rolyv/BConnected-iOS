// Copyright 2026 BConnected contributors. SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Combine
import SignalServiceKit

@MainActor
protocol BConnectedRecoveryServing: AnyObject {
    func progress() throws -> BConnectedRecoveryProgress?
    func prepare(_ input: BConnectedEnrollmentPreparation) throws
    func refresh() async throws
    func sendCode(confirmedUncertain: Bool, mayDispatch: () -> Bool) async throws
    func checkCode(_ code: String) async throws
    func replaceAccount(mayDispatch: () -> Bool) async throws
    func finishLocalSetup(explicitRetry: Bool) async throws
}
extension BConnectedRecoveryCoordinator: BConnectedRecoveryServing {}

@MainActor
final class BConnectedRecoveryViewModel: ObservableObject {
    @Published private(set) var progress: BConnectedRecoveryProgress?
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    @Published private(set) var unreadable = false
    @Published private(set) var ready = false
    @Published private(set) var online = true
    @Published var phone = ""
    @Published var code = ""
    @Published var acceptedConsequences = false
    private let service: any BConnectedRecoveryServing
    private let preparation: (String) async throws -> BConnectedEnrollmentPreparation
    private let onCompleted: () -> Void
    private var active = false
    private var fresh = false
    private var task: Task<Void, Never>?
    private var refreshAfterTask = false
    private var retryNotBefore: Date?
    @Published private(set) var clock = Date()

    init(service: any BConnectedRecoveryServing,
         preparation: @escaping (String) async throws -> BConnectedEnrollmentPreparation, onCompleted: @escaping () -> Void) {
        self.service = service; self.preparation = preparation; self.onCompleted = onCompleted
        do { try reload() } catch { unreadable = true; message = "We can’t read your saved recovery. Contact the alumni team." }
    }
    private func reload() throws {
        progress = try service.progress()
        if let saved = progress?.phone { phone = saved }
    }
    var hasSavedRecovery: Bool { progress != nil }
    var canAct: Bool { active && online && !busy && !unreadable && !ready && retryNotBefore.map({ clock >= $0 }) != false }
    var canSend: Bool { canAct && fresh && progress?.observation?.state == .verification && progress?.observation?.phoneVerified == false && progress?.observation?.nextSmsSeconds == 0 }
    var canCheck: Bool { canAct && fresh && progress?.observation?.state == .verification && progress?.observation?.phoneVerified == false && progress?.observation?.nextCheckSeconds == 0 }
    var canReplace: Bool { canAct && fresh && acceptedConsequences && progress?.observation?.state == .authorized }
    var waitSeconds: Int? { retryNotBefore.map { max(0, Int(ceil($0.timeIntervalSince(clock)))) } }
    var smsWait: Int? {
        guard let seconds = progress?.observation?.nextSmsSeconds, let observed = progress?.observedAt else { return nil }
        return max(0, Int(ceil(observed.addingTimeInterval(Double(seconds)).timeIntervalSince(clock))))
    }
    func tick(_ date: Date) { clock = date }
    func setActive(_ value: Bool) {
        guard active != value else { return }
        active = value
        if !value { code = ""; acceptedConsequences = false; fresh = false; task?.cancel() }
        else if hasSavedRecovery {
            if busy { refreshAfterTask = true } else { refresh() }
        }
    }
    func setOnline(_ value: Bool) {
        let changed = online != value; online = value
        if !value { code = ""; fresh = false; task?.cancel() }
        else if changed && active && hasSavedRecovery {
            if busy { refreshAfterTask = true } else { refresh() }
        }
    }
    private func checkActive() throws {
        try Task.checkCancellation()
        guard active && online else { throw CancellationError() }
    }
    private func run(_ action: @escaping () async throws -> Void) {
        guard canAct else { return }
        busy = true; message = nil
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do { try checkActive(); try await action(); try reload() }
            catch is CancellationError { }
            catch { handle(error) }
            do { try reload() } catch { unreadable = true }
            busy = false; task = nil
            if refreshAfterTask && active && online { refreshAfterTask = false; refresh() }
        }
    }
    func begin() {
        guard !hasSavedRecovery, acceptedConsequences,
              let canonical = BConnectedPhoneEntry.parse(phone, region: "US")?.e164 else {
            message = "Enter your phone number, including its country code, and confirm the recovery details."; return
        }
        run {
            let input = try await self.preparation(canonical)
            try self.checkActive(); try self.service.prepare(input); try self.reload()
            try await self.service.refresh(); try self.checkActive(); self.fresh = true
        }
    }
    func refresh() {
        guard hasSavedRecovery else { return }
        run {
            try await self.service.refresh(); try self.checkActive(); try self.reload(); self.fresh = true
            if self.progress?.observation?.state == .active { try await self.finish(explicitRetry: false) }
        }
    }
    func sendCode(confirmedUncertain: Bool = false) {
        guard canSend else { return }
        run {
            try await self.service.sendCode(confirmedUncertain: confirmedUncertain,
                mayDispatch: { self.active && self.online && !Task.isCancelled })
            try self.checkActive(); self.fresh = true
        }
    }
    func verifyCode() {
        guard canCheck else { return }
        let submitted = BConnectedPhoneEntry.digits(code)
        guard (4...10).contains(submitted.count), submitted.count == code.filter({ !$0.isWhitespace }).count else {
            message = "Enter the code from your text message."; return
        }
        code = ""
        run {
            try await self.service.checkCode(submitted); try self.checkActive(); self.fresh = true
        }
    }
    func replaceAccount() {
        guard canReplace else { return }
        acceptedConsequences = false
        run {
            try await self.service.replaceAccount(mayDispatch: { self.active && self.online && !Task.isCancelled })
            try self.checkActive(); try self.reload(); self.fresh = true
            if self.progress?.observation?.state == .active { try await self.finish(explicitRetry: false) }
        }
    }
    func continueSetup() {
        guard hasSavedRecovery else { return }
        run {
            try await self.service.refresh(); try self.checkActive(); try self.reload(); self.fresh = true
            if self.progress?.observation?.state == .active { try await self.finish(explicitRetry: true) }
        }
    }
    private func finish(explicitRetry: Bool) async throws {
        try await service.finishLocalSetup(explicitRetry: explicitRetry)
        try checkActive(); ready = true; code = ""; onCompleted()
    }
    private func handle(_ error: Error) {
        fresh = false
        if case BConnectedEnrollmentError.rejected(let code, let seconds) = error {
            if let seconds { retryNotBefore = Date().addingTimeInterval(Double(seconds)) }
            switch code {
            case .codeNotAccepted: message = "That code isn’t right. Check recovery status before trying again."
            case .codeExpired: message = "That code expired. Check recovery status before requesting another."
            case .rateLimited, .temporarilyUnavailable: message = "We couldn’t continue yet. Your recovery is saved. Check again when the wait ends."
            case .recoveryNotAuthorized: message = "The alumni team hasn’t authorized this recovery yet."
            case .recoveryExpired: message = "This recovery expired. Contact the alumni team; your saved records are unchanged."
            default: message = "We can’t continue this recovery. Contact the alumni team."
            }
        } else if (error as? BConnectedEnrollmentError) == .persistenceUnavailable {
            unreadable = true; message = "We can’t read your saved recovery. Contact the alumni team."
        } else if (error as? BConnectedEnrollmentError) == .immutableConflict {
            message = "Your saved account details don’t match this recovery. Contact the alumni team."
        } else if (error as? BConnectedEnrollmentError) == .explicitPublicationRetryRequired {
            message = "Your replacement is saved. Continue setup to retry the saved profile publication."
        } else { message = "We couldn’t confirm the request. Check your saved recovery before continuing." }
    }
}
