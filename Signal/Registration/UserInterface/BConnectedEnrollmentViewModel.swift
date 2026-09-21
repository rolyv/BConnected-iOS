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
    private var coordinator: BConnectedEnrollmentCoordinator?

    init(info: [String: Any] = Bundle.main.infoDictionary ?? [:], makeCoordinator: (BConnectedEnrollmentEndpoint) -> BConnectedEnrollmentCoordinator) {
        do {
            guard let string = info["BConnectedEnrollmentOrigin"] as? String,
                  let url = URL(string: string) else { throw BConnectedEnrollmentError.unavailable }
            coordinator = makeCoordinator(try BConnectedEnrollmentEndpoint(origin: url))
            progress = try coordinator?.progress()
        } catch { message = "BConnected signup is not available in this build yet." }
    }

    var title: String {
        guard let progress else { return "Welcome to BConnected" }
        guard progress.hasApprovedIntentBinding else { return "Alumni approval" }
        guard let observation = progress.lastObservation else { return "Verify your phone" }
        switch observation.state {
        case .verification: return observation.phoneVerified == true ? "Phone verified" : "Verify your phone"
        case .pendingConfirmation: return "Waiting for account confirmation"
        case .active: return "Account confirmed"
        case .suspended: return "Account unavailable"
        }
    }

    var detail: String {
        guard let progress else { return "Signup will verify your alumni membership and phone number. Invitation and approval setup is not available in this build yet." }
        guard progress.hasApprovedIntentBinding else { return "Your device setup is saved. Alumni approval must be linked before phone verification can begin." }
        if progress.smsOutcomeNeedsExplicitDecision {
            return "We could not confirm whether your last SMS request completed. Check status before deciding to send another code. Your device setup is saved."
        }
        switch progress.lastObservation?.state {
        case .verification:
            return progress.lastObservation?.phoneVerified == true
                ? "Phone verification is complete. Your messaging account still needs confirmation."
                : "Request a code, then enter it here. A code alone does not activate your account."
        case .pendingConfirmation: return "Your phone is verified. Messaging stays unavailable until membership and account confirmation finish."
        case .active: return "The server confirmed this account. Finishing device setup is not available in this build yet."
        case .suspended: return "This account cannot use messaging. Contact the alumni administrator."
        case nil: return "Start phone verification using your saved alumni approval. This step does not send a text message."
        }
    }

    var maySend: Bool {
        guard let observation = progress?.lastObservation, observation.state == .verification,
              observation.phoneVerified != true, observation.nextSmsSeconds == 0 else { return false }
        return true
    }
    var mayCheck: Bool {
        guard let observation = progress?.lastObservation, observation.state == .verification,
              observation.phoneVerified != true, observation.nextCheckSeconds == 0 else { return false }
        return true
    }

    func perform(_ operation: BConnectedEnrollmentOperation, explicitResend: Bool = false) {
        guard !busy, let coordinator else { return }
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
                } else if case BConnectedEnrollmentError.rejected(.enrollmentExpired, _) = error {
                    message = "This enrollment attempt expired. Your saved device setup has been kept; contact the administrator for help."
                } else { message = "The request could not be confirmed. Your saved device setup has been kept. Check status before retrying." }
            }
            do { progress = try coordinator.progress() }
            catch { message = "Saved signup state could not be read. No new attempt will be created." }
        }
    }
}
