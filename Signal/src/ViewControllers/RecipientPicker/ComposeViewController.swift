//
// Copyright 2019 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI
import UIKit
import LibSignalClient

class ComposeViewController: RecipientPickerContainerViewController {
    private var isBConnectedDMAlpha = false
    private var bConnectedPublication: BConnectedPublicationConfiguration?
    private var ownAlumniCode: String?
    private var alumniCodeField: UITextField?
    private var alumniStatusLabel: UILabel?
    private var lookupButton: UIButton?
    private var lookupInProgress = false
    private var lookupTask: Task<Void, Never>?

    override func viewDidLoad() {
        super.viewDidLoad()

        title = OWSLocalizedString("MESSAGE_COMPOSEVIEW_TITLE", comment: "Title for the compose view.")

        view.backgroundColor = Theme.backgroundColor
        navigationItem.rightBarButtonItem = .cancelButton(dismissingFrom: self)

        if BConnectedDMAlphaConfiguration.isForegroundTextAlphaScope {
            isBConnectedDMAlpha = true
            configureBConnectedDMAlphaComposer()
            return
        }

        recipientPicker.shouldShowInvites = true
        recipientPicker.shouldShowNewGroup = true
        recipientPicker.groupsToShow = .groupsThatUserIsMemberOfWhenSearching
        recipientPicker.shouldHideLocalRecipient = false
        recipientPicker.delegate = self

        addRecipientPicker()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard isBConnectedDMAlpha else { return }
        refreshBConnectedAccountState()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isMovingFromParent || isBeingDismissed || navigationController?.isBeingDismissed == true {
            lookupTask?.cancel()
        }
    }

    private func configureBConnectedDMAlphaComposer() {
        let info = Bundle.main.infoDictionary ?? [:]
        do {
            // This validates the complete DM-alpha scope and all explicit endpoint/trust inputs.
            _ = try BConnectedDMAlphaConfiguration(
                info: info,
                userAgent: OWSURLSession.userAgentHeaderValueSignalIos,
            )
            bConnectedPublication = try BConnectedPublicationConfiguration(info: info)
        } catch {
            bConnectedPublication = nil
        }

        let titleLabel = UILabel()
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.text = "Send a direct message"

        let explanationLabel = UILabel()
        explanationLabel.font = .preferredFont(forTextStyle: .subheadline)
        explanationLabel.textColor = .secondaryLabel
        explanationLabel.numberOfLines = 0
        explanationLabel.text = "Ask the other alumnus to share their alumni code. You can compare safety numbers in the conversation to confirm each other’s identity."

        let ownCodeLabel = UILabel()
        ownCodeLabel.font = .preferredFont(forTextStyle: .body)
        ownCodeLabel.numberOfLines = 0
        ownCodeLabel.text = "Your alumni code is available after the primary account is ready."

        let copyButton = UIButton(type: .system)
        copyButton.setTitle("Copy my alumni code", for: .normal)
        copyButton.contentHorizontalAlignment = .leading
        copyButton.addTarget(self, action: #selector(copyOwnAlumniCode), for: .touchUpInside)

        let shareButton = UIButton(type: .system)
        shareButton.setTitle("Share my alumni code", for: .normal)
        shareButton.contentHorizontalAlignment = .leading
        shareButton.addTarget(self, action: #selector(shareOwnAlumniCode(_:)), for: .touchUpInside)

        let codeLabel = UILabel()
        codeLabel.font = .preferredFont(forTextStyle: .headline)
        codeLabel.text = "Alumni code"

        let codeField = UITextField()
        codeField.borderStyle = .roundedRect
        codeField.autocapitalizationType = .none
        codeField.autocorrectionType = .no
        codeField.spellCheckingType = .no
        codeField.keyboardType = .asciiCapable
        codeField.textContentType = nil
        codeField.placeholder = "Paste alumni code"
        codeField.accessibilityLabel = "Alumni code"
        codeField.clearButtonMode = .whileEditing
        codeField.returnKeyType = .go
        codeField.addTarget(self, action: #selector(startBConnectedLookup), for: .editingDidEndOnExit)
        alumniCodeField = codeField

        let statusLabel = UILabel()
        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 0
        alumniStatusLabel = statusLabel

        let startButton = UIButton(type: .system)
        startButton.setTitle("Start conversation", for: .normal)
        startButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        startButton.tintColor = .Signal.accent
        startButton.addTarget(self, action: #selector(startBConnectedLookup), for: .touchUpInside)
        lookupButton = startButton

        let stack = UIStackView(arrangedSubviews: [
            titleLabel, explanationLabel, ownCodeLabel, copyButton, shareButton,
            codeLabel, codeField, statusLabel, startButton,
        ])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 12
        stack.setCustomSpacing(24, after: explanationLabel)
        stack.setCustomSpacing(24, after: shareButton)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let scrollView = UIScrollView()
        scrollView.keyboardDismissMode = .interactive
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        scrollView.addSubview(stack)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -24),
            stack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -40),
        ])

        alphaOwnCodeLabel = ownCodeLabel
        copyOwnCodeButton = copyButton
        shareOwnCodeButton = shareButton
        refreshBConnectedAccountState()
    }

    private var alphaOwnCodeLabel: UILabel?
    private var copyOwnCodeButton: UIButton?
    private var shareOwnCodeButton: UIButton?

    private func refreshBConnectedAccountState() {
        guard isBConnectedDMAlpha else { return }
        let account = currentBConnectedPrimaryAccount()
        ownAlumniCode = account?.aci
        alphaOwnCodeLabel?.text = account.map { "Your alumni code: \($0.aci)" }
            ?? "Your alumni code is available after the primary account is ready."
        copyOwnCodeButton?.isEnabled = account != nil
        shareOwnCodeButton?.isEnabled = account != nil

        if bConnectedPublication == nil {
            alumniStatusLabel?.text = "Messaging is unavailable because the DM-alpha endpoint or trust configuration is incomplete."
        } else if account == nil {
            alumniStatusLabel?.text = "Messaging is available only after a registered primary account is ready."
        } else {
            alumniStatusLabel?.text = nil
        }
        updateLookupButtonState()
    }

    private func updateLookupButtonState() {
        lookupButton?.isEnabled = !lookupInProgress && bConnectedPublication != nil && currentBConnectedPrimaryAccount() != nil
    }

    private func currentBConnectedPrimaryAccount() -> BConnectedPrimaryAccount? {
        return SSKEnvironment.shared.databaseStorageRef.read { transaction in
            Self.bConnectedPrimaryAccount(transaction: transaction)
        }
    }

    private static func bConnectedPrimaryAccount(transaction: DBReadTransaction) -> BConnectedPrimaryAccount? {
        let accountManager = DependenciesBridge.shared.tsAccountManager
        guard (try? accountManager.registeredState(tx: transaction)) != nil,
              let identifiers = accountManager.localIdentifiers(tx: transaction),
              accountManager.storedDeviceId(tx: transaction).ifValid == .primary,
              let password = accountManager.storedServerAuthToken(tx: transaction),
              let credentials = try? BConnectedPrimaryRecipientCredentials(
                aci: identifiers.aci.serviceIdString.lowercased(),
                password: password,
                deviceId: 1,
                userAgent: OWSURLSession.userAgentHeaderValueSignalIos,
                signalAgent: "OWI",
              ) else {
            return nil
        }
        return BConnectedPrimaryAccount(aci: identifiers.aci.serviceIdString.lowercased(), password: password, credentials: credentials)
    }

    @objc private func copyOwnAlumniCode() {
        guard let ownAlumniCode else { return }
        UIPasteboard.general.string = ownAlumniCode
        alumniStatusLabel?.text = "Your alumni code was copied."
    }

    @objc private func shareOwnAlumniCode(_ sender: UIButton) {
        guard let ownAlumniCode else { return }
        let activity = UIActivityViewController(activityItems: [ownAlumniCode], applicationActivities: nil)
        if let popover = activity.popoverPresentationController {
            popover.sourceView = sender
            popover.sourceRect = sender.bounds
        }
        present(activity, animated: true)
    }

    @objc private func startBConnectedLookup() {
        guard isBConnectedDMAlpha, !lookupInProgress else { return }
        view.endEditing(true)
        lookupTask = Task { [weak self] in
            guard let self else { return }
            await self.lookupAndPresentBConnectedConversation()
        }
    }

    private func lookupAndPresentBConnectedConversation() async {
        guard let configuration = bConnectedPublication else {
            alumniStatusLabel?.text = "Messaging is unavailable because the DM-alpha endpoint or trust configuration is incomplete."
            return
        }
        let targetACI = alumniCodeField?.text ?? ""
        guard Self.isCanonicalBConnectedAlumniCode(targetACI) else {
            alumniStatusLabel?.text = "Enter the complete alumni code exactly as it was shared."
            return
        }
        guard let account = currentBConnectedPrimaryAccount() else {
            refreshBConnectedAccountState()
            return
        }
        guard targetACI != account.aci else {
            alumniStatusLabel?.text = "Enter another member’s Alumni code, not your own."
            return
        }

        lookupInProgress = true
        lookupButton?.isEnabled = false
        alumniStatusLabel?.text = "Checking alumni code…"
        defer {
            lookupInProgress = false
            updateLookupButtonState()
        }

        do {
            let result = try await BConnectedRecipientLookupClient().lookup(
                recipientACI: targetACI,
                credentials: account.credentials,
                configuration: configuration,
            )
            guard !Task.isCancelled, viewIfLoaded?.window != nil else { return }
            guard result.aci == targetACI, result.deviceId == 1,
                  currentBConnectedPrimaryAccount() == account,
                  let recipientACI = Aci.parseFrom(aciString: result.aci),
                  let localACI = Aci.parseFrom(aciString: account.aci), recipientACI != localACI else {
                alumniStatusLabel?.text = "Your primary account changed while the code was checked. Try again."
                return
            }

            let thread = SSKEnvironment.shared.databaseStorageRef.write { transaction -> TSThread? in
                guard Self.bConnectedPrimaryAccount(transaction: transaction) == account else { return nil }
                var recipient = DependenciesBridge.shared.recipientFetcher.fetchOrCreate(serviceId: recipientACI, tx: transaction)
                DependenciesBridge.shared.recipientManager.markAsRegisteredAndSave(
                    &recipient,
                    deviceId: .primary,
                    shouldUpdateStorageService: false,
                    tx: transaction,
                )
                return TSContactThread.getOrCreateThread(
                    withContactAddress: SignalServiceAddress(recipientACI),
                    transaction: transaction,
                )
            }
            guard !Task.isCancelled, viewIfLoaded?.window != nil else { return }
            guard let thread else {
                alumniStatusLabel?.text = "Your primary account changed while the conversation was being prepared. Try again."
                return
            }
            newConversation(thread: thread)
        } catch {
            guard !Task.isCancelled, viewIfLoaded?.window != nil else { return }
            alumniStatusLabel?.text = "That Alumni code could not be verified. Check the code and try again."
        }
    }

    private static func isCanonicalBConnectedAlumniCode(_ value: String) -> Bool {
        guard let uuid = UUID(uuidString: value), uuid.uuidString.lowercased() == value else { return false }
        return value != "00000000-0000-0000-0000-000000000000"
    }

    /// Presents the conversation for the given address and dismisses this
    /// controller such that the conversation is visible.
    func newConversation(address: SignalServiceAddress) {
        AssertIsOnMainThread()
        owsAssertDebug(address.isValid)

        let thread = SSKEnvironment.shared.databaseStorageRef.write { transaction in
            TSContactThread.getOrCreateThread(
                withContactAddress: address,
                transaction: transaction,
            )
        }
        self.newConversation(thread: thread)
    }

    /// Presents the conversation for the given thread and dismisses this
    /// controller such that the conversation is visible.
    func newConversation(thread: TSThread) {
        presentingViewController?.dismiss(animated: true)
        if let transitionCoordinator = presentingViewController?.transitionCoordinator {
            // When transitionCoordinator is present, coordinate the immediate presentation of
            // the conversationVC with the animated dismissal of the compose VC
            transitionCoordinator.animate { _ in
                UIView.performWithoutAnimation {
                    SignalApp.shared.presentConversationForThread(
                        threadUniqueId: thread.uniqueId,
                        action: .compose,
                        animated: false,
                    )
                }
            }
        } else {
            // There isn't a transition coordinator present for some reason, revert to displaying
            // the conversation VC in parallel with the animated dismissal of the compose VC
            SignalApp.shared.presentConversationForThread(
                threadUniqueId: thread.uniqueId,
                action: .compose,
                animated: false,
            )
        }
    }

    func showNewGroupUI() {
        navigationController?.pushViewController(NewGroupMembersViewController(), animated: true)
    }
}

private struct BConnectedPrimaryAccount: Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let aci: String
    let password: String
    let credentials: BConnectedPrimaryRecipientCredentials

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.aci == rhs.aci && lhs.password == rhs.password
    }

    var description: String { "BConnectedPrimaryAccount(redacted)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: []) }
}

extension ComposeViewController: RecipientPickerDelegate, UsernameLinkScanDelegate {

    func recipientPicker(
        _ recipientPickerViewController: RecipientPickerViewController,
        selectionStyleForRecipient recipient: PickedRecipient,
        transaction: DBReadTransaction,
    ) -> UITableViewCell.SelectionStyle {
        return .default
    }

    func recipientPicker(
        _ recipientPickerViewController: RecipientPickerViewController,
        didSelectRecipient recipient: PickedRecipient,
    ) {
        switch recipient.identifier {
        case .address(let address):
            newConversation(address: address)
        case .group(let groupThread):
            newConversation(thread: groupThread)
        }
    }

    func recipientPicker(
        _ recipientPickerViewController: RecipientPickerViewController,
        accessoryMessageForRecipient recipient: PickedRecipient,
        transaction: DBReadTransaction,
    ) -> String? {
        switch recipient.identifier {
        case .address:
            return nil
        case .group(let thread):
            guard SSKEnvironment.shared.blockingManagerRef.isThreadBlocked(thread, transaction: transaction) else { return nil }
            return MessageStrings.conversationIsBlocked
        }
    }

    func recipientPicker(
        _ recipientPickerViewController: RecipientPickerViewController,
        attributedSubtitleForRecipient recipient: PickedRecipient,
        transaction: DBReadTransaction,
    ) -> NSAttributedString? {
        switch recipient.identifier {
        case .address(let address):
            guard !address.isLocalAddress else {
                return nil
            }
            if let bioForDisplay = SSKEnvironment.shared.profileManagerRef.userProfile(for: address, tx: transaction)?.bioForDisplay {
                return NSAttributedString(string: bioForDisplay)
            }
            return nil
        case .group:
            return nil
        }
    }

    func recipientPickerNewGroupButtonWasPressed() {
        showNewGroupUI()
    }
}
