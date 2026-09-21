// Copyright 2026 BConnected contributors. SPDX-License-Identifier: AGPL-3.0-only

import SignalServiceKit
import SwiftUI
import UIKit

/// Owned enrollment has no escape into legacy registration, linking, or recovery.
final class BConnectedEnrollmentViewController: UIHostingController<BConnectedEnrollmentView> {
    init(makeCoordinator: @MainActor (BConnectedEnrollmentEndpoint) -> BConnectedEnrollmentCoordinator) {
        let model = BConnectedEnrollmentViewModel(makeCoordinator: makeCoordinator)
        super.init(rootView: BConnectedEnrollmentView(model: model))
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Unavailable") }
}


struct BConnectedEnrollmentView: View {
    @ObservedObject var model: BConnectedEnrollmentViewModel
    @State private var confirmResend = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("BConnected").font(.headline)
                Text(model.title).font(.largeTitle).bold()
                Text(model.detail)
                if let progress = model.progress {
                    if progress.hasApprovedIntentBinding && !progress.hasOperation {
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
                    if progress.lastObservation?.state == .verification && progress.lastObservation?.phoneVerified == true {
                        Button("Request account confirmation") { model.perform(.complete) }
                    }
                    if progress.hasOperation { Button("Check status") { model.perform(.status) } }
                }
                if model.busy { ProgressView() }
                if let message = model.message { Text(message).accessibilityIdentifier("bconnected.enrollment.status") }
            }
            .padding(24).disabled(model.busy)
        }
        .navigationBarBackButtonHidden(true)
        .confirmationDialog("Send another SMS? The previous message may still arrive.", isPresented: $confirmResend) {
            Button("Send another code") { model.perform(.sendCode, explicitResend: true) }
            Button("Cancel", role: .cancel) {}
        }
    }
}
