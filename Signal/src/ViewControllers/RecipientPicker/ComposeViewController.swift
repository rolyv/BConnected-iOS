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
    private let directoryClient = BConnectedDirectoryClient()
    private var directoryMembers: [BConnectedDirectoryMember] = []
    private var directoryAccount: BConnectedDirectoryAccount?
    private var directoryQuery = ""
    private var nextOffset: Int?
    private var retryOffset = 0
    private var hasLoadedDirectory = false
    private var directoryLoading = false
    private var lookupTask: Task<Void, Never>?
    private var lookupGeneration = UUID()
    private let directoryTable = UITableView(frame: .zero, style: .plain)
    private let directorySearchBar = UISearchBar()
    private let directoryStatus = UILabel()
    private let directorySpinner = UIActivityIndicatorView(style: .medium)
    private let directoryRetryButton = UIButton(type: .system)
    private let directoryMoreButton = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        title = OWSLocalizedString("MESSAGE_COMPOSEVIEW_TITLE", comment: "Title for the compose view.")
        view.backgroundColor = Theme.backgroundColor
        navigationItem.rightBarButtonItem = .cancelButton(dismissingFrom: self)

        if BConnectedDMAlphaConfiguration.isForegroundTextAlphaScope {
            isBConnectedDMAlpha = true
            configureBConnectedDirectory()
            NotificationCenter.default.addObserver(self, selector: #selector(directoryWillResignActive), name: UIApplication.willResignActiveNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(directoryDidBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
            return
        }

        recipientPicker.shouldShowInvites = true
        recipientPicker.shouldShowNewGroup = true
        recipientPicker.groupsToShow = .groupsThatUserIsMemberOfWhenSearching
        recipientPicker.shouldHideLocalRecipient = false
        recipientPicker.delegate = self
        addRecipientPicker()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        refreshDirectoryIfNeeded()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isMovingFromParent || isBeingDismissed || navigationController?.isBeingDismissed == true {
            cancelDirectoryRequest()
        }
    }

    deinit {
        lookupTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    private func configureBConnectedDirectory() {
        let info = Bundle.main.infoDictionary ?? [:]
        do {
            _ = try BConnectedDMAlphaConfiguration(info: info, userAgent: OWSURLSession.userAgentHeaderValueSignalIos)
            bConnectedPublication = try BConnectedPublicationConfiguration(info: info)
        } catch { bConnectedPublication = nil }

        directorySearchBar.placeholder = "Name or class year"
        directorySearchBar.searchTextField.accessibilityLabel = "Search alumni by name or class year"
        directorySearchBar.autocorrectionType = .no
        directorySearchBar.autocapitalizationType = .none
        directorySearchBar.searchBarStyle = .minimal
        directorySearchBar.delegate = self

        directoryStatus.font = .preferredFont(forTextStyle: .subheadline)
        directoryStatus.adjustsFontForContentSizeCategory = true
        directoryStatus.textColor = .secondaryLabel
        directoryStatus.numberOfLines = 0
        directoryStatus.accessibilityTraits = .staticText
        directoryRetryButton.setTitle("Try again", for: .normal)
        directoryRetryButton.titleLabel?.font = .preferredFont(forTextStyle: .body)
        directoryRetryButton.titleLabel?.adjustsFontForContentSizeCategory = true
        directoryRetryButton.addTarget(self, action: #selector(retryDirectorySearch), for: .touchUpInside)
        directoryMoreButton.setTitle("Load more alumni", for: .normal)
        directoryMoreButton.titleLabel?.font = .preferredFont(forTextStyle: .body)
        directoryMoreButton.titleLabel?.adjustsFontForContentSizeCategory = true
        directoryMoreButton.addTarget(self, action: #selector(loadMoreDirectoryMembers), for: .touchUpInside)
        directoryRetryButton.isHidden = true
        directoryMoreButton.isHidden = true
        directorySpinner.hidesWhenStopped = true

        directoryTable.backgroundColor = Theme.backgroundColor
        directoryTable.dataSource = self
        directoryTable.delegate = self
        directoryTable.rowHeight = UITableView.automaticDimension
        directoryTable.estimatedRowHeight = 76
        directoryTable.sectionHeaderHeight = UITableView.automaticDimension
        directoryTable.estimatedSectionHeaderHeight = 88
        directoryTable.keyboardDismissMode = .onDrag
        directoryTable.tableFooterView = UIView()
        directoryTable.register(UITableViewCell.self, forCellReuseIdentifier: "BConnectedDirectoryMember")
        directoryTable.register(UITableViewHeaderFooterView.self, forHeaderFooterViewReuseIdentifier: "BConnectedDirectoryExplanation")

        let stack = UIStackView(arrangedSubviews: [directorySearchBar, directoryStatus, directorySpinner,
                                                 directoryRetryButton, directoryTable, directoryMoreButton])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        let retryMinimumHeight = directoryRetryButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        let moreMinimumHeight = directoryMoreButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        // UIStackView uses a required zero-height constraint for hidden arranged views.
        retryMinimumHeight.priority = UILayoutPriority(999)
        moreMinimumHeight.priority = UILayoutPriority(999)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -8),
            retryMinimumHeight,
            moreMinimumHeight,
        ])
    }

    private func currentDirectoryAccount() -> BConnectedDirectoryAccount? {
        SSKEnvironment.shared.databaseStorageRef.read { BConnectedDirectoryAccount.current(tx: $0) }
    }

    private func refreshDirectoryIfNeeded() {
        guard isBConnectedDMAlpha, viewIfLoaded?.window != nil else { return }
        if !hasLoadedDirectory || currentDirectoryAccount() != directoryAccount {
            searchDirectory(offset: 0)
        }
    }

    @objc private func directoryWillResignActive() {
        guard isBConnectedDMAlpha else { return }
        if directoryLoading {
            cancelDirectoryRequest()
            directoryStatus.text = "Search paused. Try again when you're ready."
            directoryRetryButton.isHidden = false
        }
    }

    @objc private func directoryDidBecomeActive() { refreshDirectoryIfNeeded() }

    private func cancelDirectoryRequest() {
        lookupGeneration = UUID()
        lookupTask?.cancel()
        lookupTask = nil
        setDirectoryLoading(false)
    }

    private func setDirectoryLoading(_ loading: Bool) {
        directoryLoading = loading
        directoryTable.allowsSelection = !loading
        directoryMoreButton.isEnabled = !loading
        if loading { directorySpinner.startAnimating() } else { directorySpinner.stopAnimating() }
    }

    @objc private func retryDirectorySearch() { searchDirectory(offset: retryOffset) }
    @objc private func loadMoreDirectoryMembers() {
        guard let nextOffset, !directoryLoading else { return }
        searchDirectory(offset: nextOffset)
    }

    private func searchDirectory(offset: Int, debounce: Bool = false) {
        cancelDirectoryRequest()
        let query = directorySearchBar.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        directoryQuery = query
        retryOffset = offset
        directoryRetryButton.isHidden = true
        directoryMoreButton.isHidden = true
        if offset == 0 {
            directoryMembers = []
            directoryAccount = nil
            nextOffset = nil
            hasLoadedDirectory = false
            directoryTable.reloadData()
        }
        guard let configuration = bConnectedPublication, let account = currentDirectoryAccount() else {
            directoryStatus.text = "The alumni directory is available after your account is ready."
            return
        }
        guard query.unicodeScalars.count <= 100 else {
            directoryStatus.text = "Use a shorter name or class year."
            return
        }
        let generation = lookupGeneration
        setDirectoryLoading(true)
        directoryStatus.text = "Finding alumni…"
        lookupTask = Task { [weak self] in
            guard let self else { return }
            do {
                if debounce { try await Task.sleep(nanoseconds: 300_000_000) }
                let page = try await directoryClient.search(query: query, offset: offset,
                    credentials: account.credentials, configuration: configuration)
                guard isCurrentDirectoryRequest(generation, account: account) else { return }
                SSKEnvironment.shared.databaseStorageRef.write { tx in
                    guard BConnectedDirectoryAccount.current(tx: tx) == account else { return }
                    let store = BConnectedDirectoryNameStore()
                    for member in page.members { try? store.save(member, ownerACI: account.aci, tx: tx) }
                }
                guard isCurrentDirectoryRequest(generation, account: account) else { return }
                let incoming = page.members.filter { $0.aci != account.aci }
                let incomingIDs = Set(incoming.map(\.aci))
                directoryMembers.removeAll { incomingIDs.contains($0.aci) }
                directoryMembers.append(contentsOf: incoming)
                directoryAccount = account
                nextOffset = page.nextOffset
                hasLoadedDirectory = true
                setDirectoryLoading(false)
                directoryStatus.text = directoryMembers.isEmpty
                    ? (query.isEmpty ? "No other alumni are available yet." : "No alumni found. Try another name or class year.")
                    : nil
                directoryMoreButton.isHidden = nextOffset == nil
                directoryTable.reloadData()
            } catch {
                guard generation == lookupGeneration, !Task.isCancelled, viewIfLoaded?.window != nil else { return }
                setDirectoryLoading(false)
                directoryStatus.text = "We couldn’t load the alumni directory. Try again."
                directoryRetryButton.isHidden = false
            }
        }
    }

    private func isCurrentDirectoryRequest(_ generation: UUID, account: BConnectedDirectoryAccount) -> Bool {
        guard generation == lookupGeneration, !Task.isCancelled, viewIfLoaded?.window != nil,
              UIApplication.shared.applicationState == .active else { return false }
        guard currentDirectoryAccount() == account else {
            directoryMembers = []
            directoryAccount = nil
            hasLoadedDirectory = false
            directoryTable.reloadData()
            setDirectoryLoading(false)
            directoryStatus.text = "Your account changed. Search again to continue."
            directoryRetryButton.isHidden = false
            retryOffset = 0
            return false
        }
        return true
    }

    private func selectDirectoryMember(_ member: BConnectedDirectoryMember) {
        guard !directoryLoading, let configuration = bConnectedPublication,
              let account = currentDirectoryAccount(), account == directoryAccount, member.aci != account.aci else { return }
        view.endEditing(true)
        cancelDirectoryRequest()
        let generation = lookupGeneration
        setDirectoryLoading(true)
        directoryRetryButton.isHidden = true
        directoryStatus.text = "Opening conversation…"
        lookupTask = Task { [weak self] in
            guard let self else { return }
            do {
                let resolved = try await directoryClient.resolve(aci: member.aci, credentials: account.credentials, configuration: configuration)
                guard isCurrentDirectoryRequest(generation, account: account), resolved.aci == member.aci,
                      let recipientACI = Aci.parseFrom(aciString: resolved.aci) else { return }
                let thread = SSKEnvironment.shared.databaseStorageRef.write { tx -> TSThread? in
                    guard BConnectedDirectoryAccount.current(tx: tx) == account else { return nil }
                    do { try BConnectedDirectoryNameStore().save(resolved, ownerACI: account.aci, tx: tx) }
                    catch { return nil }
                    var recipient = DependenciesBridge.shared.recipientFetcher.fetchOrCreate(serviceId: recipientACI, tx: tx)
                    DependenciesBridge.shared.recipientManager.markAsRegisteredAndSave(&recipient, deviceId: .primary,
                        shouldUpdateStorageService: false, tx: tx)
                    return TSContactThread.getOrCreateThread(withContactAddress: SignalServiceAddress(recipientACI), transaction: tx)
                }
                guard isCurrentDirectoryRequest(generation, account: account) else { return }
                setDirectoryLoading(false)
                guard let thread else { throw BConnectedEnrollmentError.persistenceUnavailable }
                newConversation(thread: thread)
            } catch {
                guard generation == lookupGeneration, !Task.isCancelled, viewIfLoaded?.window != nil else { return }
                setDirectoryLoading(false)
                directoryStatus.text = "This alumnus isn’t available right now. Try searching again."
                retryOffset = 0
                directoryRetryButton.isHidden = false
            }
        }
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

extension ComposeViewController: UISearchBarDelegate, UITableViewDataSource, UITableViewDelegate {
    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        guard searchBar.searchTextField.markedTextRange == nil else { return }
        searchDirectory(offset: 0, debounce: true)
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
        searchDirectory(offset: 0)
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { directoryMembers.count }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard let header = tableView.dequeueReusableHeaderFooterView(withIdentifier: "BConnectedDirectoryExplanation") else { return nil }
        var content = UIListContentConfiguration.groupedHeader()
        content.text = "Find alumni by name or class year. Only approved members can see this directory. Phone numbers stay private."
        content.textProperties.font = .preferredFont(forTextStyle: .subheadline)
        content.textProperties.adjustsFontForContentSizeCategory = true
        content.textProperties.color = .secondaryLabel
        content.textProperties.numberOfLines = 0
        content.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0)
        header.contentConfiguration = content
        header.backgroundConfiguration = .clear()
        return header
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "BConnectedDirectoryMember", for: indexPath)
        let member = directoryMembers[indexPath.row]
        var content = cell.defaultContentConfiguration()
        content.text = member.fullName
        content.secondaryText = "Class of \(member.graduationYear)"
        content.textProperties.font = .preferredFont(forTextStyle: .body)
        content.textProperties.numberOfLines = 0
        content.secondaryTextProperties.font = .preferredFont(forTextStyle: .subheadline)
        content.secondaryTextProperties.color = .secondaryLabel
        content.secondaryTextProperties.numberOfLines = 0
        cell.contentConfiguration = content
        cell.backgroundColor = Theme.backgroundColor
        cell.accessoryType = .disclosureIndicator
        cell.accessibilityLabel = "\(member.fullName), class of \(member.graduationYear)"
        cell.accessibilityTraits = .button
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard directoryMembers.indices.contains(indexPath.row) else { return }
        selectDirectoryMember(directoryMembers[indexPath.row])
    }
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
