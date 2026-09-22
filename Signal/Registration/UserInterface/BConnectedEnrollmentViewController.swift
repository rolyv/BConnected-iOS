// Copyright 2026 BConnected contributors. SPDX-License-Identifier: AGPL-3.0-only

import SignalServiceKit
import SwiftUI
import UIKit

/// Owned enrollment has no escape into legacy registration, linking, or recovery.
final class BConnectedEnrollmentViewController: UIHostingController<BConnectedEnrollmentView> {
    init(initialRegistration: Bool, makeCoordinator: @MainActor (BConnectedEnrollmentEndpoint) -> BConnectedEnrollmentCoordinator,
         makeCommunity: @escaping @MainActor (BConnectedEnrollmentEndpoint, BConnectedEnrollmentCoordinator) -> BConnectedCommunityEnrollmentCoordinator,
         makePreparation: @escaping @MainActor (String) async throws -> BConnectedEnrollmentPreparation) {
        let model = BConnectedEnrollmentViewModel(initialRegistration: initialRegistration, makeCoordinator: makeCoordinator, makeCommunity: makeCommunity, makePreparation: makePreparation)
        super.init(rootView: BConnectedEnrollmentView(model: model))
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Unavailable") }
}

struct BConnectedEnrollmentView: View {
    @ObservedObject var model: BConnectedEnrollmentViewModel
    @State private var confirmResend = false
    @State private var confirmIntentRetry = false
    @State private var confirmPublicationRetry = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("BConnected").font(.headline)
                Text(model.title).font(.largeTitle).bold()
                Text(model.detail)
                if model.canApply {
                    TextField("Full name", text: $model.name).textContentType(.name)
                    TextField("Graduation year", text: $model.year).keyboardType(.numberPad)
                    SecureField("Invitation code", text: $model.invitation).textInputAutocapitalization(.never)
                    Button("Request alumni approval") { model.apply() }
                }
                if model.communityProgress?.member != nil {
                    Button("Check alumni approval") { model.refreshApproval() }
                }
                if model.mayConnectMembership {
                    if model.progress == nil {
                        TextField("Phone number, including +country code", text: $model.phone).keyboardType(.phonePad).textContentType(.telephoneNumber)
                    }
                    Button(model.communityProgress?.intentOutcomeUncertain == true ? "Retry approval binding…" : "Connect approved membership") {
                        if model.communityProgress?.intentOutcomeUncertain == true { confirmIntentRetry = true }
                        else { model.connectMembership() }
                    }
                }
                if let progress = model.progress {
                    if progress.hasApprovedIntentBinding && !progress.hasOperation && model.memberAllowsVerification {
                        Button("Start phone verification") { model.perform(.begin) }
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
        .confirmationDialog("Request a new approval binding after the previous request's waiting period?", isPresented: $confirmIntentRetry) {
            Button("Retry approval binding") { model.connectMembership(explicitRetry: true) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Send another SMS? The previous message may still arrive.", isPresented: $confirmResend) {
            Button("Send another code") { model.perform(.sendCode, explicitResend: true) }
            Button("Cancel", role: .cancel) {}
        }
    }
}
