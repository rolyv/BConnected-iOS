// Copyright 2026 BConnected contributors. SPDX-License-Identifier: AGPL-3.0-only

import SignalServiceKit
import SwiftUI
import UIKit

/// Owned enrollment has no escape into legacy registration, linking, or recovery.
final class BConnectedEnrollmentViewController: UIHostingController<BConnectedEnrollmentView> {
    init(initialRegistration: Bool, makeCoordinator: @MainActor (BConnectedEnrollmentEndpoint) -> BConnectedEnrollmentCoordinator,
         makeCommunity: @escaping @MainActor (BConnectedEnrollmentEndpoint, BConnectedEnrollmentEndpoint, BConnectedEnrollmentCoordinator) -> BConnectedCommunityEnrollmentCoordinator,
         makePreparation: @escaping @MainActor (String) async throws -> BConnectedEnrollmentPreparation,
         onCompleted: @escaping @MainActor () -> Void) {
        let model = BConnectedEnrollmentViewModel(initialRegistration: initialRegistration, makeCoordinator: makeCoordinator,
            makeCommunity: makeCommunity, makePreparation: makePreparation, onCompleted: onCompleted)
        super.init(rootView: BConnectedEnrollmentView(model: model))
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Unavailable") }
}

struct BConnectedEnrollmentView: View {
    @ObservedObject var model: BConnectedEnrollmentViewModel
    @State private var confirmResend = false
    @State private var confirmPhoneResend = false
    @State private var confirmIntentRetry = false
    @State private var confirmPublicationRetry = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("BConnected").font(.headline)
                Text(model.title).font(.largeTitle).bold()
                Text(model.detail)
                if model.canApply {
                    TextField("Phone number, including +country code", text: $model.phone)
                        .keyboardType(.phonePad).textContentType(.telephoneNumber).disabled(model.retryPhoneApplication)
                    TextField("Full name", text: $model.name).textContentType(.name).disabled(model.retryPhoneApplication)
                    TextField("Class year", text: $model.year).keyboardType(.numberPad).disabled(model.retryPhoneApplication)
                    Button(model.retryPhoneApplication ? "Retry saved request" : "Continue") { model.applyPhone() }
                }
                if model.communityProgress?.phoneSignup != nil && model.communityProgress?.member == nil {
                    if model.maySendPhoneCode {
                        Button(model.communityProgress?.phoneSignup?.smsOutcomeNeedsExplicitDecision == true ? "Send another code…" : "Send verification code") {
                            if model.communityProgress?.phoneSignup?.smsOutcomeNeedsExplicitDecision == true { confirmPhoneResend = true }
                            else { model.sendPhoneCode() }
                        }
                    }
                    if model.mayCheckPhoneCode {
                        TextField("Verification code", text: $model.code).keyboardType(.numberPad).textContentType(.oneTimeCode)
                        Button("Verify phone number") { model.checkPhoneCode() }
                    }
                    if model.communityProgress?.phoneSignup?.hasOperation == true {
                        Button(model.communityProgress?.phoneSignup?.phoneVerified == true ? "Check membership status" : "Check verification status") {
                            model.refreshPhoneVerification()
                        }
                    }
                }
                if model.communityProgress?.canRestartPhoneSetup == true {
                    Button("Restart expired phone setup") { model.restartExpiredPhoneSetup() }
                }
                if model.communityProgress?.member != nil && model.communityProgress?.canRestartPhoneSetup != true {
                    Button("Check alumni approval") { model.refreshApproval() }
                }
                if model.mayConnectMembership {
                    if model.progress == nil && model.communityProgress?.savedApplicationPhone == nil {
                        TextField("Phone number, including +country code", text: $model.phone).keyboardType(.phonePad).textContentType(.telephoneNumber)
                    }
                    Button(model.communityProgress?.intentOutcomeUncertain == true ? "Retry setup…" : "Set up messaging") {
                        if model.communityProgress?.intentOutcomeUncertain == true { confirmIntentRetry = true }
                        else { model.connectMembership() }
                    }
                }
                if let progress = model.progress {
                    if progress.hasApprovedIntentBinding && !progress.hasOperation && model.memberAllowsVerification {
                        Button(model.communityProgress?.savedApplicationPhone == nil ? "Start phone verification" : "Continue messaging setup") { model.perform(.begin) }
                    }
                    if model.maySend {
                        Button(progress.smsOutcomeNeedsExplicitDecision ? "Send another code…" : "Send SMS code") {
                            if progress.smsOutcomeNeedsExplicitDecision { confirmResend = true }
                            else { model.perform(.sendCode) }
                        }
                    }
                    if model.mayCheck {
                        TextField("Verification code", text: $model.code)
                            .keyboardType(.numberPad).textContentType(.oneTimeCode)
                        Button("Verify code") { model.perform(.checkCode) }
                    }
                    if model.memberAllowsVerification && progress.lastObservation?.state == .verification && progress.lastObservation?.phoneVerified == true {
                        Button("Request account confirmation") { model.perform(.complete) }
                    }
                    if model.memberAllowsVerification && progress.lastObservation?.state == .active && !progress.nativeAccountInstalled {
                        Button("Save account on this iPhone") { model.installNativeAccount() }
                    }
                    if progress.nativeAccountInstalled && !progress.localAccountPrepared {
                        Button("Prepare local account") { model.prepareLocalAccount() }
                    }
                    if progress.localAccountPrepared && !progress.accountEntropyPrepared {
                        Button("Finish local setup") { model.prepareAccountEntropy() }
                    }
                    if model.mayPublishAccount {
                        Button(progress.accountPublicationNeedsExplicitRetry ? "Retry saved profile publication…" : "Publish saved profile") {
                            if progress.accountPublicationNeedsExplicitRetry { confirmPublicationRetry = true }
                            else { model.publishAccount() }
                        }
                    }
                    if model.mayPublishPreKeys {
                        Button("Publish saved device setup") { model.publishPreKeys() }
                    }
                    if model.mayVerifyPublishedAccount {
                        Button("Verify saved account and profile") { model.verifyPublishedAccount() }
                    }
                    if model.mayCompleteDMAlpha {
                        Button("Finish foreground messaging setup") { model.completeDMAlpha() }
                    }
                    if progress.hasOperation { Button("Check status") { model.perform(.status) } }
                }
                if model.busy { ProgressView() }
                if let message = model.message { Text(message).accessibilityIdentifier("bconnected.enrollment.status") }
            }
            .padding(24).disabled(model.busy)
        }
        .navigationBarBackButtonHidden(true)
        .confirmationDialog("The server may already have accepted this setup request. Send the same saved request again?", isPresented: $confirmPublicationRetry) {
            Button("Retry saved publication") { model.publishAccount(explicitRetry: true) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Your previous setup request may have gone through. Retry it after the waiting period?", isPresented: $confirmIntentRetry) {
            Button("Retry setup") { model.connectMembership(explicitRetry: true) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Send another SMS? The previous message may still arrive.", isPresented: $confirmResend) {
            Button("Send another code") { model.perform(.sendCode, explicitResend: true) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Send another verification text? The previous message may still arrive.", isPresented: $confirmPhoneResend) {
            Button("Send another code") { model.sendPhoneCode(explicitResend: true) }
            Button("Cancel", role: .cancel) {}
        }
    }
}
