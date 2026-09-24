// Copyright 2026 BConnected contributors. SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Combine
import SignalServiceKit

@MainActor
protocol BConnectedSignupCommunity: AnyObject {
    func progress() throws -> BConnectedCommunityProgress
    func draft() throws -> BConnectedSignupDraft?
    func saveDraft(_ draft: BConnectedSignupDraft) throws
    func applyPhone(name: String, year: Int, phone: String) async throws
    func sendPhoneCode(explicitlyResendAfterUncertainOutcome: Bool, mayDispatch: () -> Bool) async throws
    func checkPhoneCode(_ code: String) async throws
    func refreshPhoneVerification() async throws
    func refreshApproval() async throws
    func connectApprovedMembership(preparation: () async throws -> BConnectedEnrollmentPreparation, explicitlyRetryLostIntent: Bool) async throws
}
extension BConnectedCommunityEnrollmentCoordinator: BConnectedSignupCommunity {}

@MainActor
protocol BConnectedSignupAccount: AnyObject {
    func progress() throws -> BConnectedEnrollmentProgress?
    func perform(_ operation: BConnectedEnrollmentOperation, code: String?, explicitlyResendAfterUncertainOutcome: Bool) async throws -> BConnectedEnrollmentObservation
    func installNativeAccount() async throws
    func prepareLocalAccount() throws
    func prepareAccountEntropy() throws
    func publishAccount(explicitlyRetryUncertainOutcome: Bool) async throws
    func publishPreKeys() async throws
    func completeDMAlpha() async throws
}
extension BConnectedEnrollmentCoordinator: BConnectedSignupAccount {}

/// A presentation projection over the two encrypted journals, never another enrollment ledger.
/// All network effects enter through one main-actor task. Foreground/status/timers do not grant retries.
@MainActor
final class BConnectedEnrollmentViewModel: ObservableObject {
    enum Screen: Equatable { case details, verifying, returning, resolvingMembership, pending, settingUp, continuation, help, declined, accessPaused, ready }
    enum Field: Hashable { case phone, name, year, code }
    @Published private(set) var screen: Screen = .details
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    @Published private(set) var progress: BConnectedEnrollmentProgress?
    @Published private(set) var communityProgress: BConnectedCommunityProgress?
    @Published var phone = ""
    @Published var region = "US"
    @Published var name = ""
    @Published var year = ""
    @Published var code = ""
    @Published private(set) var errors: [Field: String] = [:]
    @Published private(set) var invalidField: Field?
    @Published private(set) var isOnline = true
    @Published private(set) var slow = false
    @Published private(set) var clock = Date()
    @Published private(set) var stateUnreadable = false
    @Published private(set) var codeExpired = false
    private var community: (any BConnectedSignupCommunity)?
    private var coordinator: (any BConnectedSignupAccount)?
    private let makePreparation: (@MainActor (String) async throws -> BConnectedEnrollmentPreparation)?
    private let onCompleted: @MainActor () -> Void
    private var task: Task<Void, Never>?
    private var active = false
    private var freshPhoneObservation = false
    private var polls = 0
    private var nextPoll: Date?
    private var startedAt: Date?
    private var setupStartedAt: Date?
    private var completed = false
    private var resumeAfterTask = false
    private var requestRetryNotBefore: Date?

    init(info: [String: Any] = Bundle.main.infoDictionary ?? [:], initialRegistration: Bool = true,
         makeCoordinator: (BConnectedEnrollmentEndpoint) -> BConnectedEnrollmentCoordinator,
         makeCommunity: ((BConnectedEnrollmentEndpoint, BConnectedEnrollmentEndpoint, BConnectedEnrollmentCoordinator) -> BConnectedCommunityEnrollmentCoordinator)? = nil,
         makePreparation: (@MainActor (String) async throws -> BConnectedEnrollmentPreparation)? = nil,
         onCompleted: @escaping @MainActor () -> Void = {}) {
        self.makePreparation = makePreparation; self.onCompleted = onCompleted
        guard initialRegistration else { screen = .help; return }
        do {
            guard let origin = info["BConnectedEnrollmentOrigin"] as? String, let url = URL(string: origin),
                  let communityOrigin = info["BConnectedCommunityOrigin"] as? String, let communityURL = URL(string: communityOrigin),
                  let makeCommunity else { throw BConnectedEnrollmentError.unavailable }
            let endpoint = try BConnectedEnrollmentEndpoint(origin: url)
            let communityEndpoint = try BConnectedEnrollmentEndpoint(origin: communityURL)
            let coordinator = makeCoordinator(endpoint)
            self.coordinator = coordinator
            self.community = makeCommunity(communityEndpoint, endpoint, coordinator)
            try restore()
        } catch { stateUnreadable = true; screen = .help }
    }

    /// Tests use the same driver with deterministic coordinators and no network or account.
    init(community: any BConnectedSignupCommunity, coordinator: any BConnectedSignupAccount,
         makePreparation: @escaping @MainActor (String) async throws -> BConnectedEnrollmentPreparation,
         onCompleted: @escaping @MainActor () -> Void = {}) {
        self.community = community; self.coordinator = coordinator
        self.makePreparation = makePreparation; self.onCompleted = onCompleted
        do { try restore() } catch { stateUnreadable = true; screen = .help }
    }

    private func reload() throws {
        do { communityProgress = try community?.progress(); progress = try coordinator?.progress() }
        catch { stateUnreadable = true; screen = .help; throw error }
    }

    private func restore() throws {
        try reload()
        if let draft = try community?.draft() {
            phone = draft.phone; region = draft.region; name = draft.name; year = draft.year
        }
        if let saved = communityProgress?.savedApplicationPhone { phone = saved }
        if let saved = communityProgress?.savedApplicationName { name = saved }
        if let saved = communityProgress?.savedApplicationYear { year = String(saved) }
        screen = hasSavedSetup ? .returning : .details
    }

    var hasSavedSetup: Bool { communityProgress?.savedApplicationPhone != nil || communityProgress?.member != nil || progress != nil || communityProgress?.applicationOutcomeUncertain == true }
    var frozen: Bool { communityProgress?.savedApplicationPhone != nil || hasSavedSetup }
    var memberName: String { communityProgress?.member?.fullName ?? name }
    var memberYear: String { communityProgress?.member.map { String($0.graduationYear) } ?? year }
    var phoneDestination: String { communityProgress?.savedApplicationPhone.map { PhoneNumber.bestEffortLocalizedPhoneNumber(e164: $0) } ?? phone }
    var uncertainSMS: Bool { communityProgress?.phoneSignup?.smsOutcomeNeedsExplicitDecision == true }
    var canSend: Bool { active && isOnline && !busy && freshPhoneObservation && communityProgress?.phoneSignup?.phoneVerified != true && communityProgress?.phoneSignup?.nextSmsSeconds == 0 }
    var canCheck: Bool { active && isOnline && !busy && !codeExpired && freshPhoneObservation && communityProgress?.phoneSignup?.hasOperation == true && communityProgress?.phoneSignup?.phoneVerified != true && communityProgress?.phoneSignup?.nextCheckSeconds == 0 }
    private var continuationNotBefore: Date? { [communityProgress?.intentRetryNotBefore, requestRetryNotBefore].compactMap { $0 }.max() }
    var canContinue: Bool { isOnline && !busy && !stateUnreadable && (continuationNotBefore.map { clock >= $0 } ?? true) }
    var intentWait: Int? { continuationNotBefore.map { max(0, Int(ceil($0.timeIntervalSince(clock)))) } }
    var smsWait: Int? { remaining(communityProgress?.phoneSignup?.nextSmsSeconds) }
    var checkWait: Int? { remaining(communityProgress?.phoneSignup?.nextCheckSeconds) }
    private func remaining(_ seconds: Int?) -> Int? {
        guard let seconds, let observed = communityProgress?.phoneSignup?.observedAt, clock >= observed else { return nil }
        return max(0, Int(ceil(observed.addingTimeInterval(Double(seconds)).timeIntervalSince(clock))))
    }
    static func duration(_ seconds: Int) -> String { String(format: "%d:%02d", seconds / 60, seconds % 60) }
    var resendTitle: String {
        if let seconds = smsWait, seconds > 0 { return "Send another code in \(Self.duration(seconds))" }
        if communityProgress?.phoneSignup?.hasOperation != true { return "Send code" }
        return canSend ? "Send another code" : "Checking when you can send another code…"
    }
    var checkNotice: String? {
        if codeExpired { return nil }
        if let seconds = checkWait, seconds > 0 { return "Too many tries. Try again in \(Self.duration(seconds))." }
        if !canCheck && !busy { return "Please wait before trying again. We’ll check when you can continue." }
        return nil
    }

    func saveDraft() {
        guard !frozen, screen == .details else { return }
        do { try community?.saveDraft(.init(phone: phone, region: region, name: name, year: year)) }
        catch { stateUnreadable = true; screen = .help }
    }

    @discardableResult
    func validate(_ field: Field? = nil) -> Bool {
        let fields = field.map { [$0] } ?? [.phone, .name, .year]
        for item in fields {
            errors[item] = nil
            switch item {
            case .phone:
                if phone.isEmpty { errors[item] = "Enter your phone number." }
                else if BConnectedPhoneEntry.parse(phone, region: region) == nil { errors[item] = "Check the number and country code." }
            case .name:
                let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                if name.isEmpty { errors[item] = "Enter your full name." }
                else if name.utf16.count > 100 || name.unicodeScalars.contains(where: { $0.value < 32 || (127...159).contains($0.value) }) {
                    errors[item] = "Check your full name."
                } else if let parsed = OWSUserProfile.NameComponent.parse(truncating: name), !parsed.didTruncate, parsed.nameComponent.stringValue.rawValue == name {
                    // The complete display name fits the native profile; never infer name parts.
                } else { errors[item] = "This name is too long for your profile. Try a shorter version." }
            case .year:
                let upper = Calendar(identifier: .gregorian).component(.year, from: Date())
                if year.count != 4 || Int(year).map({ !(1940...upper).contains($0) }) != false { errors[item] = "Enter a year from 1940 to \(upper)." }
            case .code: break
            }
        }
        if field == nil { invalidField = [.phone, .name, .year].first { errors[$0] != nil } }
        return fields.allSatisfy { errors[$0] == nil }
    }

    func setActive(_ value: Bool) {
        active = value
        if !value {
            code = ""; task?.cancel(); nextPoll = nil; freshPhoneObservation = false
        } else { polls = 0; if busy { resumeAfterTask = true } else { resume() } }
    }
    func setOnline(_ value: Bool) {
        let changed = isOnline != value
        isOnline = value
        if !value {
            // Cancellation revokes the pending user action even if connectivity returns
            // before its current request finishes. A reconnect may reconcile, never send later.
            task?.cancel(); freshPhoneObservation = false; nextPoll = nil
        }
        else if changed && active { polls = 0; if busy { resumeAfterTask = true } else { resume() } }
    }
    func tick(_ date: Date = Date()) {
        clock = date
        if screen == .settingUp || screen == .resolvingMembership {
            if setupStartedAt == nil { setupStartedAt = startedAt ?? date }
            slow = date.timeIntervalSince(setupStartedAt!) >= 10
        } else { setupStartedAt = nil; slow = false }
        guard active, isOnline, !busy, let nextPoll, date >= nextPoll else { return }
        self.nextPoll = nil
        resume()
    }
    private func checkActive() throws {
        try Task.checkCancellation()
        guard active, isOnline else { throw CancellationError() }
    }
    func resume() {
        guard hasSavedSetup, screen != .help, screen != .ready else { return }
        if let requestRetryNotBefore, Date() < requestRetryNotBefore {
            nextPoll = requestRetryNotBefore
            return
        }
        run { try await self.reconcileAndDrive(explicitRetry: false) }
    }
    func submitDetails() {
        guard screen == .details, active, isOnline, !busy, !stateUnreadable, !frozen, validate(), let e164 = BConnectedPhoneEntry.parse(phone, region: region)?.e164,
              let community, let year = Int(year) else { return }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        run {
            self.screen = .verifying
            self.message = "Sending your code…"
            try await community.applyPhone(name: name, year: year, phone: e164)
            try self.reload()
            try self.checkActive()
            try await community.sendPhoneCode(explicitlyResendAfterUncertainOutcome: false, mayDispatch: { self.active && self.isOnline && !Task.isCancelled })
            try self.reload()
            self.message = nil
            self.freshPhoneObservation = true
            try await self.reconcileAndDrive(explicitRetry: false)
        }
    }
    func sendCode(confirmedUncertain: Bool = false) {
        guard canSend, let community, !uncertainSMS || confirmedUncertain else { return }
        polls = 0
        run {
            try await community.refreshPhoneVerification()
            try self.reload(); self.freshPhoneObservation = true
            try self.checkActive()
            if self.communityProgress?.phoneSignup?.phoneVerified != true {
                self.message = "Sending your code…"
                try await community.sendPhoneCode(explicitlyResendAfterUncertainOutcome: confirmedUncertain, mayDispatch: { self.active && self.isOnline && !Task.isCancelled })
            }
            self.codeExpired = false; self.errors[.code] = nil
            self.message = nil
            try await self.reconcileAndDrive(explicitRetry: false)
        }
    }
    func verifyCode() {
        guard canCheck, let community else { return }
        let submitted = BConnectedPhoneEntry.digits(code)
        guard (4...10).contains(submitted.count), submitted.count == code.filter({ !$0.isWhitespace }).count else {
            errors[.code] = "Enter the code from your text message."; return
        }
        code = ""; errors[.code] = nil
        polls = 0
        run {
            try await community.refreshPhoneVerification()
            try self.reload(); try self.checkActive()
            if self.communityProgress?.phoneSignup?.phoneVerified != true { try await community.checkPhoneCode(submitted) }
            try await self.reconcileAndDrive(explicitRetry: false)
        }
    }
    func continueSetup() {
        guard canContinue else { return }
        polls = 0
        run { try await self.reconcileAndDrive(explicitRetry: true) }
    }

    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard active, isOnline, !busy, !stateUnreadable, community != nil, coordinator != nil, !completed else { return }
        busy = true; startedAt = Date(); nextPoll = nil
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do { try checkActive(); try await action() }
            catch is CancellationError { /* Durable receipts survive. No deferred user intent. */ }
            catch { handle(error) }
            do { try reload() } catch { screen = .help }
            busy = false; startedAt = nil; task = nil
            if active && resumeAfterTask {
                resumeAfterTask = false; resume()
            } else if active { schedulePoll() }
        }
    }

    private func reconcileAndDrive(explicitRetry: Bool) async throws {
        guard let community, let coordinator else { return }
        try reload(); try checkActive()
        if communityProgress?.applicationOutcomeUncertain == true {
            guard let phone = communityProgress?.savedApplicationPhone, let name = communityProgress?.savedApplicationName,
                  let year = communityProgress?.savedApplicationYear else { screen = .help; return }
            // Exact frozen application replay is idempotent and never sends SMS.
            try await community.applyPhone(name: name, year: year, phone: phone)
            try reload(); try checkActive()
        }
        guard communityProgress?.canRestartPhoneSetup != true else { screen = .help; return }
        if communityProgress?.phoneSignup != nil && communityProgress?.member == nil {
            screen = communityProgress?.phoneSignup?.phoneVerified == true ? .resolvingMembership : .verifying
            try await community.refreshPhoneVerification()
            try reload(); try checkActive(); freshPhoneObservation = true
            if communityProgress?.member == nil {
                screen = communityProgress?.phoneSignup?.phoneVerified == true ? .resolvingMembership : .verifying
                return
            }
        }
        guard communityProgress?.member != nil else { screen = hasSavedSetup ? .help : .details; return }
        try await community.refreshApproval()
        try reload(); try checkActive()
        switch communityProgress?.member?.status {
        case .pending: screen = .pending; message = nil; return
        case .rejected: screen = .declined; return
        case .suspended: screen = .accessPaused; return
        case .approved: break
        case nil: screen = .help; return
        }
        guard communityProgress?.phoneSignup?.phoneVerified == true, let phone = communityProgress?.savedApplicationPhone,
              let makePreparation else { screen = .help; return }
        screen = .settingUp; message = nil
        if progress?.hasApprovedIntentBinding != true {
            if communityProgress?.intentOutcomeUncertain == true && (!explicitRetry || !canRetryIntent) { screen = .continuation; return }
            try await community.connectApprovedMembership(preparation: { try self.checkActive(); return try await makePreparation(phone) },
                explicitlyRetryLostIntent: explicitRetry && communityProgress?.intentOutcomeUncertain == true)
            try reload(); try checkActive()
        }
        let observation = try await coordinator.perform(progress?.hasOperation == true ? .status : .begin, code: nil, explicitlyResendAfterUncertainOutcome: false)
        try reload(); try checkActive()
        switch observation.state {
        case .suspended: screen = .accessPaused; return
        case .pendingConfirmation: return
        case .verification:
            // The only accepted primary path reuses the verified phone. Never enter legacy SMS.
            guard observation.phoneVerified == true else { screen = .help; return }
            let completed = try await coordinator.perform(.complete, code: nil, explicitlyResendAfterUncertainOutcome: false)
            try reload(); try checkActive()
            if completed.state == .suspended { screen = .accessPaused; return }
            guard completed.state == .active, completed.registrationAuthorized else { return }
        case .active:
            guard observation.registrationAuthorized else { screen = .help; return }
        }
        if progress?.preKeyPublicationBlocked == true { screen = .help; return }
        if progress?.nativeAccountInstalled != true { try await coordinator.installNativeAccount(); try reload(); try checkActive() }
        if progress?.localAccountPrepared != true { try coordinator.prepareLocalAccount(); try reload(); try checkActive() }
        if progress?.accountEntropyPrepared != true { try coordinator.prepareAccountEntropy(); try reload(); try checkActive() }
        if progress?.accountPublicationComplete != true {
            if progress?.accountPublicationNeedsExplicitRetry == true && !explicitRetry { screen = .continuation; return }
            try await coordinator.publishAccount(explicitlyRetryUncertainOutcome: explicitRetry && progress?.accountPublicationNeedsExplicitRetry == true)
            try reload(); try checkActive()
        }
        if progress?.preKeyPublicationComplete != true { try await coordinator.publishPreKeys(); try reload(); try checkActive() }
        // This includes fresh remote acceptance and the final native DB transaction.
        try await coordinator.completeDMAlpha()
        completed = true; screen = .ready; code = ""; onCompleted()
    }
    private var canRetryIntent: Bool { communityProgress?.intentRetryNotBefore.map { Date() >= $0 } ?? true }

    private func handle(_ error: Error) {
        do { try reload() } catch { stateUnreadable = true; screen = .help; return }
        if case BConnectedEnrollmentError.rejected(let reason, let seconds) = error,
           reason == .rateLimited || reason == .temporarilyUnavailable, let seconds {
            requestRetryNotBefore = Date().addingTimeInterval(Double(seconds))
        }
        if case BConnectedEnrollmentError.rejected(.codeExpired, _) = error {
            codeExpired = true; freshPhoneObservation = false
            errors[.code] = "That code has expired. Request a new one."; screen = .verifying
        } else if case BConnectedEnrollmentError.rejected(.codeNotAccepted, _) = error {
            errors[.code] = "That code isn’t right. Try again."; screen = .verifying
        } else if case BConnectedEnrollmentError.rejected(.rateLimited, _) = error {
            freshPhoneObservation = false
            message = "Please wait before trying again. We’ll check when you can continue."
            if communityProgress?.member?.status == .pending { screen = .pending }
            else if communityProgress?.member == nil {
                screen = communityProgress?.phoneSignup?.phoneVerified == true ? .resolvingMembership : .verifying
            } else { screen = .continuation }
        } else if case BConnectedEnrollmentError.phoneEnrollmentRejected = error {
            screen = .details; errors[.phone] = "This number can’t be used right now. Check it or contact the alumni team."
        } else if let error = error as? BConnectedEnrollmentError, [.invalidInput, .invalidResponse, .immutableConflict, .persistenceUnavailable, .uncertainPreKeyPublication].contains(error) {
            stateUnreadable = error == .persistenceUnavailable; screen = .help
        } else if case BConnectedEnrollmentError.rejected(let reason, _) = error, [.invalidCredentials, .enrollmentExpired, .enrollmentConflict, .enrollmentUnavailable].contains(reason) {
            screen = .help
        } else if communityProgress?.member?.status == .pending {
            screen = .pending; message = "We couldn’t check for an update. Your request is still saved."
        } else if communityProgress?.phoneSignup != nil && communityProgress?.member == nil {
            freshPhoneObservation = false
            screen = communityProgress?.phoneSignup?.phoneVerified == true ? .resolvingMembership : .verifying
            message = uncertainSMS ? "Your text may still be on its way. Enter the code if it arrives." : "We couldn’t confirm the request. We’ll check where you left off."
        } else { screen = .continuation }
    }

    private func schedulePoll() {
        guard isOnline, !stateUnreadable else { return }
        if screen == .pending {
            nextPoll = max(Date().addingTimeInterval(30), requestRetryNotBefore ?? .distantPast)
            return
        }
        guard [.verifying, .resolvingMembership, .settingUp].contains(screen), polls < 4 else {
            if screen == .settingUp || screen == .resolvingMembership { screen = .continuation }
            return
        }
        let waits: [TimeInterval] = [2, 5, 10, 20]
        var delay = waits[polls]
        if screen == .verifying {
            let positive = [smsWait, checkWait].compactMap { $0 }.filter { $0 > 0 }
            if let shortest = positive.min() { delay = max(delay, Double(shortest)) }
            else if freshPhoneObservation && (canCheck || codeExpired) && canSend { return }
        }
        nextPoll = max(Date().addingTimeInterval(delay), requestRetryNotBefore ?? .distantPast); polls += 1
    }
}

/// Uses the app's libphonenumber metadata, including shared calling codes and national prefixes.
enum BConnectedPhoneEntry {
    static func digits(_ text: String) -> String {
        String(text.unicodeScalars.compactMap { scalar -> Character? in
            guard CharacterSet.decimalDigits.contains(scalar), let value = Character(String(scalar)).wholeNumberValue else { return nil }
            return Character(String(value))
        })
    }
    /// Linear digit-relative mapping. The app's general edit-distance mapper is quadratic
    /// and can stall the main thread on an accidental long clipboard paste.
    static func cursorOffset(from source: String, offset: Int, to target: String, preferRight: Bool) -> Int {
        let offset = max(0, min(offset, source.utf16.count))
        if source == target { return offset }
        let before = String(decoding: source.utf16.prefix(offset), as: UTF16.self)
        let targetDigits = digits(target).count
        // National formatting may remove a calling code and add a trunk prefix.
        let wanted = max(0, min(targetDigits, digits(before).count + targetDigits - digits(source).count))
        let units = Array(target.utf16)
        var seen = 0, position = 0
        while position < units.count && seen < wanted {
            if (48...57).contains(units[position]) { seen += 1 }
            position += 1
        }
        if preferRight {
            while position < units.count && !(48...57).contains(units[position]) { position += 1 }
        }
        return position
    }

    static func normalized(_ text: String) -> String {
        String(text.map { character in
            let converted = digits(String(character))
            return converted.count == 1 ? Character(converted) : character
        })
    }
    static func parse(_ text: String, region: String, using utility: PhoneNumberUtil = PhoneNumberUtil()) -> PhoneNumber? {
        let value = normalized(text)
        guard value.utf16.count <= 256, digits(value).count <= 16,
              value.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "+0123456789 ()-.\u{00a0}").contains($0) }),
              value.filter({ $0 == "+" }).count <= 1,
              !value.contains("+") || value.trimmingCharacters(in: .whitespaces).hasPrefix("+") else { return nil }
        return utility.parsePhoneNumber(countryCode: region, nationalNumber: value)
    }
}
