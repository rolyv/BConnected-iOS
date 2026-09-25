// Copyright 2026 BConnected contributors. SPDX-License-Identifier: AGPL-3.0-only

public import Foundation

/// Display metadata in the existing encrypted database. A cached name never grants messaging access.
public struct BConnectedDirectoryNameStore {
    private let store = KeyValueStore(collection: "BConnectedDirectoryNames.v1")
    private struct Record: Codable { let member: BConnectedDirectoryMember; let observedAt: Date }

    public init() {}

    public func member(aci: String, ownerACI: String, tx: DBReadTransaction) -> BConnectedDirectoryMember? {
        record(aci: aci, ownerACI: ownerACI, tx: tx)?.member
    }

    public func needsRefresh(aci: String, ownerACI: String, now: Date = Date(), tx: DBReadTransaction) -> Bool {
        guard let record = record(aci: aci, ownerACI: ownerACI, tx: tx) else { return true }
        return now.timeIntervalSince(record.observedAt) >= 24 * 60 * 60 || record.observedAt > now
    }

    public func save(_ member: BConnectedDirectoryMember, ownerACI: String, now: Date = Date(), tx: DBWriteTransaction) throws {
        _ = try BConnectedEnrollmentWire.uuid(ownerACI)
        let data = try JSONEncoder().encode(member)
        _ = try BConnectedDirectoryClient.member(BConnectedEnrollmentWire.object(data))
        try store.setCodable(Record(member: member, observedAt: now), key: key(aci: member.aci, ownerACI: ownerACI), transaction: tx)
        tx.addSyncCompletion {
            NotificationCenter.default.postOnMainThread(name: .OWSContactsManagerSignalAccountsDidChange, object: nil)
        }
    }

    private func record(aci: String, ownerACI: String, tx: DBReadTransaction) -> Record? {
        guard (try? BConnectedEnrollmentWire.uuid(aci)) != nil, (try? BConnectedEnrollmentWire.uuid(ownerACI)) != nil,
              let data = store.getData(key(aci: aci, ownerACI: ownerACI), transaction: tx),
              let record = try? JSONDecoder().decode(Record.self, from: data), record.member.aci == aci,
              let memberData = try? JSONEncoder().encode(record.member),
              (try? BConnectedDirectoryClient.member(BConnectedEnrollmentWire.object(memberData))) != nil else { return nil }
        return record
    }

    private func key(aci: String, ownerACI: String) -> String { ownerACI + ":" + aci }
}

/// One request at a time, at most 20 different labels per foreground, with a retry cooldown.
/// Callers only enqueue ACIs already being displayed; this never enumerates the directory.
@MainActor
public final class BConnectedDirectoryNameResolver: NSObject {
    private static let shared = BConnectedDirectoryNameResolver()
    private let currentAccount: () -> BConnectedDirectoryAccount?
    private let resolve: (String, BConnectedDirectoryAccount) async throws -> BConnectedDirectoryMember
    private let persist: (BConnectedDirectoryMember, BConnectedDirectoryAccount) -> Void
    private let now: () -> Date
    private var isActive: Bool
    private var queue: [(String, BConnectedDirectoryAccount)] = []
    private var attempts: [String: Date] = [:]
    private var foregroundCount = 0
    private var task: Task<Void, Never>?
    private var generation = UUID()

    #if TESTABLE_BUILD
    var currentTaskForTesting: Task<Void, Never>? { task }
    func waitUntilIdleForTesting() async {
        while let task { await task.value }
    }
    #endif

    private convenience override init() {
        let client = BConnectedDirectoryClient()
        self.init(isActive: CurrentAppContext().isMainAppAndActive,
            currentAccount: { SSKEnvironment.shared.databaseStorageRef.read { BConnectedDirectoryAccount.current(tx: $0) } },
            resolve: { aci, account in
                let configuration = try BConnectedPublicationConfiguration(info: Bundle.main.infoDictionary ?? [:])
                return try await client.resolve(aci: aci, credentials: account.credentials, configuration: configuration)
            },
            persist: { member, account in
                SSKEnvironment.shared.databaseStorageRef.write { tx in
                    guard BConnectedDirectoryAccount.current(tx: tx) == account else { return }
                    try? BConnectedDirectoryNameStore().save(member, ownerACI: account.aci, tx: tx)
                }
            })
        NotificationCenter.default.addObserver(self, selector: #selector(didBecomeActive), name: .OWSApplicationDidBecomeActive, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(willResignActive), name: .OWSApplicationWillResignActive, object: nil)
    }

    init(isActive: Bool, currentAccount: @escaping () -> BConnectedDirectoryAccount?,
         resolve: @escaping (String, BConnectedDirectoryAccount) async throws -> BConnectedDirectoryMember,
         persist: @escaping (BConnectedDirectoryMember, BConnectedDirectoryAccount) -> Void,
         now: @escaping () -> Date = Date.init) {
        self.isActive = isActive
        self.currentAccount = currentAccount
        self.resolve = resolve
        self.persist = persist
        self.now = now
        super.init()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    public nonisolated static func enqueue(aci: String) {
        Task { @MainActor in shared.enqueueIfNeeded(aci: aci) }
    }

    func enqueueIfNeeded(aci: String) {
        guard isActive, let account = currentAccount(), aci != account.aci,
              (try? BConnectedEnrollmentWire.uuid(aci)) != nil, foregroundCount < 20 else { return }
        let key = account.aci + ":" + aci
        let instant = now()
        guard attempts[key].map({ instant.timeIntervalSince($0) >= 5 * 60 }) ?? true else { return }
        // Reserve the budget before starting work, so repeated cell rendering cannot enqueue duplicates.
        attempts[key] = instant
        foregroundCount += 1
        queue.append((aci, account))
        drain()
    }

    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        generation = UUID()
        task?.cancel()
        task = nil
        queue.removeAll()
        if active {
            foregroundCount = 0
            let cutoff = now().addingTimeInterval(-5 * 60)
            attempts = attempts.filter { $0.value > cutoff }
        }
    }

    @objc private func didBecomeActive() { setActive(true) }
    @objc private func willResignActive() { setActive(false) }

    private func drain() {
        guard isActive, task == nil, !queue.isEmpty else { return }
        let (aci, account) = queue.removeFirst()
        guard currentAccount() == account else { queue.removeAll(); return }
        let generation = generation
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.generation == generation {
                    task = nil
                    drain()
                }
            }
            do {
                let member = try await resolve(aci, account)
                guard !Task.isCancelled, isActive, self.generation == generation,
                      currentAccount() == account, member.aci == aci else { return }
                persist(member, account)
            } catch { /* An unavailable name leaves the existing local display unchanged. */ }
        }
    }
}
