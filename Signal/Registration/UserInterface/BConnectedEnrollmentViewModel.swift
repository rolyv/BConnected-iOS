// Copyright 2026 BConnected contributors. SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Combine
import SignalServiceKit

@MainActor
final class BConnectedEnrollmentViewModel: ObservableObject {
    @Published private(set) var progress: BConnectedEnrollmentProgress?
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    @Published var code = ""
    @Published var name = ""
    @Published var year = ""
    @Published var phone = ""
    @Published private(set) var communityProgress: BConnectedCommunityProgress?
    private var community: BConnectedCommunityEnrollmentCoordinator?
    private let makePreparation: (@MainActor (String) async throws -> BConnectedEnrollmentPreparation)?
    private let onCompleted: @MainActor () -> Void
    private let initialRegistration: Bool
    private var coordinator: BConnectedEnrollmentCoordinator?

    init(info: [String: Any] = Bundle.main.infoDictionary ?? [:], initialRegistration: Bool = true,
         makeCoordinator: (BConnectedEnrollmentEndpoint) -> BConnectedEnrollmentCoordinator,
         makeCommunity: ((BConnectedEnrollmentEndpoint, BConnectedEnrollmentEndpoint, BConnectedEnrollmentCoordinator) -> BConnectedCommunityEnrollmentCoordinator)? = nil,
         makePreparation: (@MainActor (String) async throws -> BConnectedEnrollmentPreparation)? = nil,
         onCompleted: @escaping @MainActor () -> Void = {}) {
        self.makePreparation = makePreparation
        self.onCompleted = onCompleted
        self.initialRegistration = initialRegistration
        guard initialRegistration else {
            message = "Account recovery, phone changes, and linked devices are not available in this pilot. Contact the alumni administrator."
            return
        }
        do {
            guard let string = info["BConnectedEnrollmentOrigin"] as? String,
                  let url = URL(string: string) else { throw BConnectedEnrollmentError.unavailable }
            let signupEndpoint = try BConnectedEnrollmentEndpoint(origin: url)
            coordinator = makeCoordinator(signupEndpoint)
            progress = try coordinator?.progress()
            if let makeCommunity, let coordinator {
                guard let origin = info["BConnectedCommunityOrigin"] as? String, let url = URL(string: origin) else {
                    throw BConnectedEnrollmentError.unavailable
                }
                community = makeCommunity(try BConnectedEnrollmentEndpoint(origin: url), signupEndpoint, coordinator)
                communityProgress = try community?.progress()
                if let saved = communityProgress?.savedApplicationPhone { phone = saved }
                if let saved = communityProgress?.savedApplicationName { name = saved }
                if let saved = communityProgress?.savedApplicationYear { year = String(saved) }
            }
        } catch { message = "BConnected signup is not available in this build yet." }
    }

    var canApply: Bool {
        community != nil && communityProgress?.member == nil && communityProgress?.phoneSignup == nil
            && (communityProgress?.applicationOutcomeUncertain == false || communityProgress?.savedApplicationPhone != nil)
    }
    var retryPhoneApplication: Bool { communityProgress?.applicationOutcomeUncertain == true && communityProgress?.savedApplicationPhone != nil }
    var maySendPhoneCode: Bool {
        communityProgress?.member == nil && communityProgress?.phoneSignup?.hasChallenge == true
            && communityProgress?.canRestartPhoneSetup != true
            && communityProgress?.phoneSignup?.phoneVerified != true
            && communityProgress?.phoneSignup?.nextSmsSeconds == 0
    }
    var mayCheckPhoneCode: Bool {
        communityProgress?.member == nil && communityProgress?.phoneSignup?.hasOperation == true
            && communityProgress?.phoneSignup?.phoneVerified != true
            && communityProgress?.phoneSignup?.nextCheckSeconds == 0
    }
    var memberAllowsVerification: Bool {
        communityProgress?.member?.status == .approved && communityProgress?.canRestartPhoneSetup != true
    }
    var mayConnectMembership: Bool {
        memberAllowsVerification && progress?.hasApprovedIntentBinding != true
            && (communityProgress?.intentRetryNotBefore.map { Date() >= $0 } ?? true)
    }
    var mayPublishAccount: Bool {
        coordinator?.supportsAccountPublication == true && memberAllowsVerification && progress?.lastObservation?.state == .active
            && progress?.accountEntropyPrepared == true
            && progress?.accountPublicationComplete != true
    }

    var mayPublishPreKeys: Bool {
        coordinator?.supportsPreKeyPublication == true && memberAllowsVerification && progress?.lastObservation?.state == .active
            && progress?.accountPublicationComplete == true && progress?.preKeyPublicationComplete != true
            && progress?.preKeyPublicationBlocked != true
    }

    var mayVerifyPublishedAccount: Bool {
        coordinator?.supportsAccountAcceptance == true && memberAllowsVerification && progress?.lastObservation?.state == .active
            && progress?.accountPublicationComplete == true && progress?.preKeyPublicationComplete == true
            && progress?.preKeyPublicationBlocked != true
    }

    var mayCompleteDMAlpha: Bool {
        mayVerifyPublishedAccount && coordinator?.supportsDMAlphaCompletion == true
    }

    var title: String {
        guard initialRegistration else { return "Account setup unavailable" }
        if let member = communityProgress?.member, member.status != .approved {
            return member.status == .pending ? "Waiting for approval" : "Membership unavailable"
        }
        if communityProgress?.phoneSignup != nil && communityProgress?.member == nil { return "Verify your phone" }
        guard let progress else {
            return communityProgress?.member?.status == .approved ? "Set up messaging" : "Welcome to BConnected"
        }
        guard progress.hasApprovedIntentBinding else { return "Set up messaging" }
        guard let observation = progress.lastObservation else {
            return communityProgress?.savedApplicationPhone == nil ? "Verify your phone" : "Set up messaging"
        }
        switch observation.state {
        case .verification: return observation.phoneVerified == true ? "Phone verified" : "Verify your phone"
        case .pendingConfirmation: return "Waiting for account confirmation"
        case .active: return progress.nativeAccountInstalled ? "Device account saved" : "Account confirmed"
        case .suspended: return "Account unavailable"
        }
    }

    var detail: String {
        guard initialRegistration else { return "This pilot supports the first signup on one iPhone per alumnus. Your existing account data has been kept." }
        if communityProgress?.applicationOutcomeUncertain == true {
            return communityProgress?.savedApplicationPhone == nil
                ? "Your previous application may have been received. Contact the alumni administrator before applying again."
                : "Your phone enrollment may have been received. Retry the same saved request to recover its response. No verification text is sent by this step."
        }
        if communityProgress?.canRestartPhoneSetup == true {
            return "This phone setup session expired. Restart with your phone number to continue. This step does not send a text."
        }
        if let signup = communityProgress?.phoneSignup, communityProgress?.member == nil {
            if signup.phoneVerified { return "Your phone was verified. Check membership status while the service finishes its approval decision." }
            if signup.smsOutcomeNeedsExplicitDecision {
                return "We could not confirm whether the SMS request completed. Check status before deciding to send another code."
            }
            return "Send a verification code to your saved phone number, then enter it here. Your application will be reviewed after phone verification."
        }
        if let member = communityProgress?.member, member.status != .approved {
            return member.status == .pending ? "Your application is waiting for administrator approval. Check back here to continue." : "Your membership is not approved for messaging. Contact the alumni administrator."
        }
        if communityProgress?.intentOutcomeUncertain == true {
            return "Your setup request may have gone through. Wait five minutes, check approval, then choose Retry if needed. Your progress is saved."
        }
        if communityProgress?.member?.status == .approved && progress?.hasApprovedIntentBinding != true {
            return communityProgress?.savedApplicationPhone == nil
                ? "Your alumni membership is approved. Continue setup and verify your phone number."
                : "Your phone number and alumni membership are verified. Continue setting up messaging on this iPhone."
        }
        if canApply { return "Enter your phone number, name, and class year. After phone verification, approved numbers can continue; other applications wait for review." }
        guard let progress else { return "Signup will verify your alumni membership and phone number. Phone enrollment is not available in this build yet." }
        guard progress.hasApprovedIntentBinding else { return "Your progress is saved. Continue setup after alumni approval is confirmed." }
        if progress.preKeyPublicationBlocked {
            return "This saved device setup needs administrator review before continuing. Messaging remains unavailable. Your keys have been kept."
        }
        if progress.preKeyPublicationUncertain {
            return "We could not confirm the saved device setup request. You can publish the same saved request again when the service is available. Messaging remains unavailable."
        }
        if progress.smsOutcomeNeedsExplicitDecision {
            return "We could not confirm whether your last SMS request completed. Check status before deciding to send another code. Your device setup is saved."
        }
        switch progress.lastObservation?.state {
        case .verification:
            return progress.lastObservation?.phoneVerified == true
                ? "Phone verification is complete. Your messaging account still needs confirmation."
                : "Request a code, then enter it here. A code alone does not activate your account."
        case .pendingConfirmation: return "Your phone is verified. Messaging stays unavailable until membership and account confirmation finish."
        case .active: return progress.nativeAccountInstalled
            ? (progress.localAccountPrepared
                ? (progress.accountEntropyPrepared
                    ? (progress.accountPublicationComplete
                        ? (progress.preKeyPublicationComplete
                            ? "Your saved profile and device setup were accepted. Messaging will become available when the remaining services are ready."
                            : "Your saved profile was accepted. Publish this iPhone's saved device setup to continue.")
                        : "This iPhone's local setup is saved. Publish your saved profile when the service is available to continue.")
                    : "This iPhone's account is saved. Finish local setup to continue.")
                : "This iPhone's account and keys are saved. Prepare the local account to continue setup.")
            : "The server confirmed this account. Save the verified account and its original keys on this iPhone to continue setup."
        case .suspended: return "This account cannot use messaging. Contact the alumni administrator."
        case nil: return "Start phone verification using your saved alumni approval. This step does not send a text message."
        }
    }

    var maySend: Bool {
        guard memberAllowsVerification, let observation = progress?.lastObservation, observation.state == .verification,
              observation.phoneVerified != true, observation.nextSmsSeconds == 0 else { return false }
        return true
    }
    var mayCheck: Bool {
        guard memberAllowsVerification, let observation = progress?.lastObservation, observation.state == .verification,
              observation.phoneVerified != true, observation.nextCheckSeconds == 0 else { return false }
        return true
    }

    func applyPhone() {
        guard let community, let year = Int(year), canApply else { message = "Enter your phone number, full name, and class year."; return }
        let name = name, phone = phone
        runCommunity { try await community.applyPhone(name: name, year: year, phone: phone) }
    }

    func refreshApproval() {
        guard let community else { return }
        runCommunity { try await community.refreshApproval() }
    }

    func sendPhoneCode(explicitResend: Bool = false) {
        guard let community, maySendPhoneCode else { return }
        runCommunity { try await community.sendPhoneCode(explicitlyResendAfterUncertainOutcome: explicitResend) }
    }

    func checkPhoneCode() {
        guard let community, mayCheckPhoneCode else { return }
        let submitted = code
        code = ""
        runCommunity { try await community.checkPhoneCode(submitted) }
    }

    func refreshPhoneVerification() {
        guard let community, communityProgress?.phoneSignup != nil,
              communityProgress?.phoneSignup?.hasOperation == true,
              communityProgress?.member == nil else { return }
        runCommunity { try await community.refreshPhoneVerification() }
    }

    func restartExpiredPhoneSetup() {
        guard !busy, communityProgress?.canRestartPhoneSetup == true else { return }
        do {
            try community?.restartExpiredPhoneSetup()
            communityProgress = try community?.progress()
            message = nil
        } catch { message = "The saved phone setup could not be restarted. No enrollment or verification request was sent." }
    }

    func connectMembership(explicitRetry: Bool = false) {
        guard let community, let makePreparation else { return }
        let phone = communityProgress?.savedApplicationPhone ?? phone
        runCommunity {
            try await community.connectApprovedMembership(preparation: { try await makePreparation(phone) }, explicitlyRetryLostIntent: explicitRetry)
        }
    }

    private func runCommunity(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true; message = nil
        Task { @MainActor in
            defer { busy = false }
            do { try await action() }
            catch BConnectedEnrollmentError.phoneEnrollmentRejected {
                message = "This phone setup is unavailable. Check the number and try again. No verification text was sent."
            }
            catch { message = "The signup request could not be confirmed. Your saved setup has been kept. Check approval or contact the alumni administrator." }
            do { communityProgress = try community?.progress(); progress = try coordinator?.progress() }
            catch { message = "Saved signup state could not be read. No new attempt will be created." }
        }
    }

    func prepareLocalAccount() {
        guard !busy, let coordinator else { return }
        busy = true; defer { busy = false }
        do { try coordinator.prepareLocalAccount(); progress = try coordinator.progress(); message = nil }
        catch { message = "Local setup could not be confirmed. Your original account and profile have been kept. Contact the alumni administrator." }
    }

    func prepareAccountEntropy() {
        guard !busy, let coordinator else { return }
        busy = true; defer { busy = false }
        do { try coordinator.prepareAccountEntropy(); progress = try coordinator.progress(); message = nil }
        catch { message = "Local setup could not be confirmed. Your saved account and keys have been kept. Contact the alumni administrator." }
    }

    func publishAccount(explicitRetry: Bool = false) {
        guard !busy, mayPublishAccount, let coordinator else { return }
        busy = true; message = nil
        Task { @MainActor in
            defer { busy = false }
            do { try await coordinator.publishAccount(explicitlyRetryUncertainOutcome: explicitRetry) }
            catch { message = "Profile publication could not be confirmed. Your saved account, profile and publication request have been kept. Check status before explicitly retrying." }
            do { progress = try coordinator.progress() }
            catch { message = "Saved signup state could not be read. No new attempt will be created." }
        }
    }

    func publishPreKeys() {
        guard !busy, mayPublishPreKeys, let coordinator else { return }
        busy = true; message = nil
        Task { @MainActor in
            defer { busy = false }
            do { try await coordinator.publishPreKeys() }
            catch { message = "Device setup could not be confirmed. Your saved keys have been kept. Contact the alumni administrator before continuing." }
            do { progress = try coordinator.progress() }
            catch { message = "Saved signup state could not be read. No new attempt will be created." }
        }
    }

    func verifyPublishedAccount() {
        guard !busy, mayVerifyPublishedAccount, let coordinator else { return }
        busy = true; message = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                try await coordinator.verifyPublishedAccount()
                message = "The service returned this iPhone's saved account and profile. Messaging remains unavailable while the remaining setup is completed."
            } catch { message = "The saved account and profile could not be verified. Your setup has been kept. Check status before trying again." }
            do { progress = try coordinator.progress() }
            catch { message = "Saved signup state could not be read. No new attempt will be created." }
        }
    }

    func completeDMAlpha() {
        guard !busy, mayCompleteDMAlpha, let coordinator else { return }
        busy = true; message = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                try await coordinator.completeDMAlpha()
                onCompleted()
            } catch {
                message = "Foreground messaging could not be confirmed. The saved account and keys are unchanged. Check status before trying again."
                do { progress = try coordinator.progress() }
                catch { message = "Saved signup state could not be read. No new attempt will be created." }
            }
        }
    }

    func installNativeAccount() {
        guard !busy, memberAllowsVerification, let coordinator else { return }
        busy = true; message = nil
        Task { @MainActor in
            defer { busy = false }
            do { try await coordinator.installNativeAccount() }
            catch { message = "Device setup could not be confirmed. Your original account and keys have been kept. Check status or contact the alumni administrator." }
            do { progress = try coordinator.progress() }
            catch { message = "Saved signup state could not be read. No new attempt will be created." }
        }
    }

    func perform(_ operation: BConnectedEnrollmentOperation, explicitResend: Bool = false) {
        guard !busy, let coordinator, operation == .status || memberAllowsVerification else { return }
        busy = true; message = nil
        let submittedCode = operation == .checkCode ? code : nil
        if operation == .checkCode { code = "" }
        Task { @MainActor in
            defer { busy = false }
            do {
                _ = try await coordinator.perform(operation, code: submittedCode, explicitlyResendAfterUncertainOutcome: explicitResend)
            } catch {
                // Never display raw transport, parser, or credential details.
                if case BConnectedEnrollmentError.rejected(.codeNotAccepted, _) = error {
                    message = "That code was not accepted. Check status before trying again."
                } else if case BConnectedEnrollmentError.rejected(.enrollmentUnavailable, _) = error {
                    message = "This membership binding is unavailable. Your saved device setup has been kept. Check alumni approval or contact the administrator."
                } else if case BConnectedEnrollmentError.rejected(.enrollmentExpired, _) = error {
                    message = "This enrollment attempt expired. Your saved device setup has been kept; contact the administrator for help."
                } else { message = "The request could not be confirmed. Your saved device setup has been kept. Check status before retrying." }
            }
            do { progress = try coordinator.progress() }
            catch { message = "Saved signup state could not be read. No new attempt will be created." }
        }
    }
}
