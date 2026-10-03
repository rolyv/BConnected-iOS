//
// Copyright 2019 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import Darwin
public import GRDB
import UIKit

/// Metadata only. This never calls the normal directory resolver, which can repair the selector
/// file, and never opens a database. Names and paths are used locally but cannot enter the report.
public enum BConnectedDatabaseDiagnostics {
    public enum State: String, Codable { case present, missing, unavailable, unsafe, notInspected }
    public enum SelectorState: String, Codable { case valid, missing, invalid, unreadable, unsafe, notInspected }
    public enum FolderCategory: String, Codable { case defaultFolder, customFolder, unsafe, unavailable }
    public enum SelectorSource: String, Codable { case file, defaults, defaultFallback, unavailable }
    public enum ScanState: String, Codable { case complete, incomplete, unavailable, notInspected }
    public enum SizeCategory: String, Codable {
        case empty, underOneMiB, oneToTenMiB, tenToHundredMiB, hundredMiBOrMore, unknown
    }

    public struct DatabaseFile: Codable, Equatable {
        public let state: State
        public let sizeCategory: SizeCategory
        /// Only the selected database reports exact bytes; alternates report categories only.
        public let sizeBytes: UInt64?
    }

    public struct Report: Codable {
        public let baseDirectory: State
        public let selectedFolder: FolderCategory
        public let selectorSource: SelectorSource
        public let selectorFile: SelectorState
        public let defaultsSelectorPresent: Bool
        public let defaultsSelectorValid: Bool?
        public let defaultsSelectorMatchesFile: Bool?
        public let selectedDatabase: DatabaseFile
        public let alternateScan: ScanState
        /// Nil means the count is unknown, including when inspection hit its bound.
        public let alternateDirectoryCount: Int?
        public let alternateDatabases: [DatabaseFile]

        public var sanitizedDescription: String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            guard let data = try? encoder.encode(self), let text = String(data: data, encoding: .utf8) else {
                return "{\"diagnostic\":\"unavailable\"}"
            }
            return text
        }
    }

    private static let maximumSelectorBytes = 1024
    private static let maximumAlternateEntries = 64
    private static let notInspected = DatabaseFile(state: .notInspected, sizeCategory: .unknown, sizeBytes: nil)

    /// `baseDirectory` must be the app's already-authorized database container. No alternate
    /// database is selected, opened or repaired. This is a best-effort observation, not a snapshot.
    public static func report(baseDirectory: URL, defaultsSelector: String?, fileManager: FileManager = .default) -> Report {
        let defaultsValid = defaultsSelector.map(validFolderName)
        let base = baseDirectory.standardizedFileURL
        let baseState = baseDirectory.isFileURL ? directoryState(base, fileManager) : .unsafe
        guard baseDirectory.isFileURL, baseState == .present else {
            return Report(baseDirectory: baseDirectory.isFileURL ? baseState : .unsafe,
                selectedFolder: .unavailable, selectorSource: .unavailable, selectorFile: .notInspected,
                defaultsSelectorPresent: defaultsSelector != nil, defaultsSelectorValid: defaultsValid,
                defaultsSelectorMatchesFile: nil, selectedDatabase: notInspected,
                alternateScan: .notInspected, alternateDirectoryCount: nil, alternateDatabases: [])
        }

        let selector = inspectSelector(base.appendingPathComponent("storedPrimaryFolderName.txt"), fileManager)
        let selectedName: String?
        let source: SelectorSource
        switch selector.state {
        case .valid:
            selectedName = selector.name; source = .file
        case .missing:
            selectedName = defaultsSelector ?? "grdb"
            source = defaultsSelector == nil ? .defaultFallback : .defaults
        case .invalid, .unreadable, .unsafe, .notInspected:
            // The live resolver might fall back after a failed file read. Do not claim a selection
            // while that evidence is unavailable, or inspect a path from malformed selector data.
            selectedName = nil; source = .unavailable
        }
        let selectedCategory: FolderCategory
        let selectedDatabase: DatabaseFile
        if let selectedName {
            if validFolderName(selectedName) {
                selectedCategory = selectedName == "grdb" ? .defaultFolder : .customFolder
                selectedDatabase = inspectDatabase(in: base.appendingPathComponent(selectedName),
                    exactSize: true, fileManager: fileManager)
            } else {
                selectedCategory = .unsafe; selectedDatabase = notInspected
            }
        } else {
            selectedCategory = .unavailable; selectedDatabase = notInspected
        }

        var scan: ScanState = .complete
        var alternates: [DatabaseFile] = []
        do {
            // A single, non-recursive listing; file metadata checks and output are capped.
            let names = try fileManager.contentsOfDirectory(atPath: base.path)
                .filter { $0.hasPrefix("grdb") && $0 != selectedName }.sorted()
            if names.count > maximumAlternateEntries { scan = .incomplete }
            for name in names.prefix(maximumAlternateEntries) {
                guard validFolderName(name) else { scan = .incomplete; continue }
                let directory = base.appendingPathComponent(name)
                switch directoryState(directory, fileManager) {
                case .present:
                    alternates.append(inspectDatabase(in: directory, exactSize: false, fileManager: fileManager))
                case .missing:
                    scan = .incomplete // The listing changed during inspection.
                case .unsafe, .unavailable, .notInspected:
                    scan = .incomplete
                }
            }
        } catch {
            scan = .unavailable
        }
        // Order by public metadata, never by a private folder name in the serialized result.
        alternates.sort {
            ($0.state.rawValue + $0.sizeCategory.rawValue) < ($1.state.rawValue + $1.sizeCategory.rawValue)
        }
        return Report(baseDirectory: .present, selectedFolder: selectedCategory, selectorSource: source,
            selectorFile: selector.state, defaultsSelectorPresent: defaultsSelector != nil,
            defaultsSelectorValid: defaultsValid,
            defaultsSelectorMatchesFile: selector.name.flatMap { name in defaultsSelector.map { $0 == name } },
            selectedDatabase: selectedDatabase, alternateScan: scan,
            alternateDirectoryCount: scan == .complete ? alternates.count : nil, alternateDatabases: alternates)
    }

    private static func validFolderName(_ name: String) -> Bool {
        guard name.utf8.prefix(256).count <= 255, name.hasPrefix("grdb") else { return false }
        return name.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0)
            || (97...122).contains($0) || $0 == 45 || $0 == 95 }
    }

    private enum Observation { case missing, unavailable, present([FileAttributeKey: Any]) }

    private static func attributes(_ url: URL, _ fileManager: FileManager) -> Observation {
        do { return .present(try fileManager.attributesOfItem(atPath: url.path)) }
        catch {
            let error = error as NSError
            if error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) {
                return .missing
            }
            return .unavailable
        }
    }

    private static func directoryState(_ url: URL, _ fileManager: FileManager) -> State {
        switch attributes(url, fileManager) {
        case .missing: return .missing
        case .unavailable: return .unavailable
        case .present(let values): return values[.type] as? FileAttributeType == .typeDirectory ? .present : .unsafe
        }
    }

    private static func inspectDatabase(in directory: URL, exactSize: Bool, fileManager: FileManager) -> DatabaseFile {
        let directoryStatus = directoryState(directory, fileManager)
        guard directoryStatus == .present else {
            return DatabaseFile(state: directoryStatus, sizeCategory: .unknown, sizeBytes: nil)
        }
        switch attributes(directory.appendingPathComponent("signal.sqlite"), fileManager) {
        case .missing: return DatabaseFile(state: .missing, sizeCategory: .unknown, sizeBytes: nil)
        case .unavailable: return DatabaseFile(state: .unavailable, sizeCategory: .unknown, sizeBytes: nil)
        case .present(let values):
            guard values[.type] as? FileAttributeType == .typeRegular else {
                return DatabaseFile(state: .unsafe, sizeCategory: .unknown, sizeBytes: nil)
            }
            let size = (values[.size] as? NSNumber)?.uint64Value
            let category: SizeCategory
            if let size {
                switch size {
                case 0: category = .empty
                case 1..<(1024 * 1024): category = .underOneMiB
                case (1024 * 1024)..<(10 * 1024 * 1024): category = .oneToTenMiB
                case (10 * 1024 * 1024)..<(100 * 1024 * 1024): category = .tenToHundredMiB
                default: category = .hundredMiBOrMore
                }
            } else {
                category = .unknown
            }
            return DatabaseFile(state: .present, sizeCategory: category, sizeBytes: exactSize ? size : nil)
        }
    }

    private static func inspectSelector(_ url: URL, _ fileManager: FileManager) -> (state: SelectorState, name: String?) {
        switch attributes(url, fileManager) {
        case .missing: return (.missing, nil)
        case .unavailable: return (.unreadable, nil)
        case .present(let values):
            guard values[.type] as? FileAttributeType == .typeRegular else { return (.unsafe, nil) }
            guard let size = (values[.size] as? NSNumber)?.uint64Value,
                  size > 0, size <= UInt64(maximumSelectorBytes) else { return (.invalid, nil) }
        }
        // NOFOLLOW closes the selector-file symlink race; NONBLOCK prevents a substituted FIFO
        // from blocking launch. Revalidate the opened file and read at most 1025 bytes.
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return (.unreadable, nil) }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else { return (.unreadable, nil) }
        guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { return (.unsafe, nil) }
        var bytes = [UInt8](repeating: 0, count: maximumSelectorBytes + 1)
        let count = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
        guard count >= 0 else { return (.unreadable, nil) }
        guard count > 0, count <= maximumSelectorBytes,
              let name = String(bytes: bytes.prefix(count), encoding: .utf8), validFolderName(name) else {
            return (.invalid, nil)
        }
        return (.valid, name)
    }
}

public class GRDBDatabaseStorageAdapter {

    public enum DirectoryMode: Int {
        public static let commonGRDBPrefix = "grdb"
        public static var primaryFolderNameKey: String { "GRDBPrimaryDirectoryNameKey" }
        public static var transferFolderNameKey: String { "GRDBTransferDirectoryNameKey" }

        static var storedTransferFolderName: String? {
            get { CurrentAppContext().appUserDefaults().string(forKey: transferFolderNameKey) }
            set { CurrentAppContext().appUserDefaults().set(newValue, forKey: transferFolderNameKey) }
        }

        /// A static directory that always stored our primary database
        case primaryLegacy
        /// A static directory that served as the temporary home of our post-restore database
        case hotswapLegacy
        /// A dynamic directory that refers to the current location of our primary database (defaults to "grdb" initially), but can post-restore
        case primary

        /// A dynamic directory that refers to a staging directory that our post-restore database is setup in during restoration
        @available(iOSApplicationExtension, unavailable)
        case transfer

        /// The name for a given directoryMode
        /// All directory modes will always be non-nil *except* for the transfer directory
        /// It is incorrect to request a transfer directory without first calling `createNewTransferDirectory()`
        var folderName: String! {
            let result: String?
            switch self {
            case .primary: result = GRDBDatabaseStorageAdapter.storedPrimaryFolderName() ?? DirectoryMode.primaryLegacy.folderName
            case .transfer: result = Self.storedTransferFolderName
            case .primaryLegacy: result = "grdb"
            case .hotswapLegacy: result = "grdb-hotswap"
            }
            owsAssertDebug(result?.hasPrefix(Self.commonGRDBPrefix) != false)
            return result
        }

        static func updateTransferDirectoryName() {
            storedTransferFolderName = "\(Self.commonGRDBPrefix)_\(Date.ows_millisecondTimestamp())_\(Int.random(in: 0..<1000))"
        }
    }

    public static func databaseDirUrl(directoryMode: DirectoryMode = .primary) -> URL {
        return SDSDatabaseStorage.baseDir.appendingPathComponent(directoryMode.folderName, isDirectory: true)
    }

    public static func databaseFileUrl(directoryMode: DirectoryMode = .primary) -> URL {
        let databaseDir = databaseDirUrl(directoryMode: directoryMode)
        OWSFileSystem.ensureDirectoryExists(databaseDir.path)
        return databaseDir.appendingPathComponent("signal.sqlite", isDirectory: false)
    }

    public static func databaseWalUrl(directoryMode: DirectoryMode = .primary) -> URL {
        let databaseDir = databaseDirUrl(directoryMode: directoryMode)
        OWSFileSystem.ensureDirectoryExists(databaseDir.path)
        return databaseDir.appendingPathComponent("signal.sqlite-wal", isDirectory: false)
    }

    fileprivate static func storedPrimaryFolderNameFileUrl() -> URL {
        return SDSDatabaseStorage.baseDir.appendingPathComponent("storedPrimaryFolderName.txt", isDirectory: false)
    }

    fileprivate static func storedPrimaryFolderName() -> String? {
        // Try and read from the file on disk.
        let fileUrl = storedPrimaryFolderNameFileUrl()
        if
            OWSFileSystem.fileOrFolderExists(url: fileUrl),
            let primaryFolderName = try? String(contentsOfFile: fileUrl.path, encoding: .utf8),
            // Should never be empty, but this is a precautionary measure.
            !primaryFolderName.isEmpty
        {
            return primaryFolderName
        }
        if let primaryFolderName = CurrentAppContext().appUserDefaults().string(forKey: DirectoryMode.primaryFolderNameKey) {
            // Make sure it's also written to the file.
            OWSFileSystem.ensureDirectoryExists(fileUrl.deletingLastPathComponent().path)
            try? primaryFolderName.write(toFile: fileUrl.path, atomically: true, encoding: .utf8)
            return primaryFolderName
        }
        return nil
    }

    fileprivate static func writeStoredPrimaryFolderName(_ newPrimaryFolderName: String) {
        CurrentAppContext().appUserDefaults().set(newPrimaryFolderName, forKey: DirectoryMode.primaryFolderNameKey)
        // Make sure it's also written to the file.
        let fileUrl = storedPrimaryFolderNameFileUrl()
        OWSFileSystem.ensureDirectoryExists(fileUrl.deletingLastPathComponent().path)
        try? newPrimaryFolderName.write(toFile: fileUrl.path, atomically: true, encoding: .utf8)

        DarwinNotificationCenter.postNotification(name: .primaryDBFolderNameDidChange)
    }

    private let checkpointQueue = DispatchQueue(label: "org.signal.checkpoint", qos: .utility)
    private let checkpointState = AtomicValue<CheckpointState>(CheckpointState(), lock: .init())

    private struct CheckpointState {
        var counter = 0

        var workItem: DispatchWorkItem?

        var backgroundTask: OWSBackgroundTask?
    }

    private let databaseChangeObserver: DatabaseChangeObserver

    private let databaseFileUrl: URL

    private let storage: GRDBStorage

    public var pool: DatabasePool {
        return storage.pool
    }

    init(
        databaseChangeObserver: DatabaseChangeObserver,
        databaseFileUrl: URL,
        keyFetcher: GRDBKeyFetcher,
    ) throws {
        self.databaseChangeObserver = databaseChangeObserver
        self.databaseFileUrl = databaseFileUrl

        try GRDBDatabaseStorageAdapter.ensureDatabaseKeySpecExists(keyFetcher: keyFetcher)

        self.storage = try GRDBStorage(dbURL: databaseFileUrl, keyFetcher: keyFetcher)
    }

    deinit {
        if let darwinToken, DarwinNotificationCenter.isValid(darwinToken) {
            DarwinNotificationCenter.removeObserver(darwinToken)
        }
    }

    // MARK: - DatabasePathObservation

    private var darwinToken: DarwinNotificationCenter.ObserverToken?

    public func setUpDatabasePathKVO() {
        darwinToken = DarwinNotificationCenter.addObserver(
            name: .primaryDBFolderNameDidChange,
            queue: .main,
            block: { [weak self] token in
                self?.primaryDBFolderNameDidChange(darwinNotificationToken: token)
            },
        )
    }

    private func primaryDBFolderNameDidChange(darwinNotificationToken: Int32) {
        checkForDatabasePathChange()
    }

    private func checkForDatabasePathChange() {
        if databaseFileUrl != GRDBDatabaseStorageAdapter.databaseFileUrl() {
            Logger.warn("Remote process changed the active database path. Exiting...")
            Logger.flush()
            exit(0)
        } else {
            Logger.info("Spurious database change observation")
        }
    }

    // MARK: - DatabaseChangeObserver

    func setupDatabaseChangeObserver() throws {
        // DatabaseChangeObserver is a general purpose observer, whose delegates
        // are notified when things change, but are not given any specific details
        // about the changes.
        try databaseChangeObserver.beginObserving(pool: pool)
    }

    func testing_tearDownDatabaseChangeObserver() throws {
        // DatabaseChangeObserver is a general purpose observer, whose delegates
        // are notified when things change, but are not given any specific details
        // about the changes.
        try databaseChangeObserver.stopObserving(pool: pool)
    }

    // MARK: -

    private static func ensureDatabaseKeySpecExists(keyFetcher: GRDBKeyFetcher) throws {
        // Because we use kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, the
        // keychain will be inaccessible after device restart until device is
        // unlocked for the first time. If the app receives a push notification, we
        // won't be able to access the keychain to process that notification, so we
        // should just terminate by throwing an uncaught exception.
        do {
            _ = try keyFetcher.fetchString()
        } catch KeychainError.notFound {
            try keyFetcher.generateAndStore()
            // belt and suspenders: make sure we can fetch it
            _ = try keyFetcher.fetchString()
        }
    }

    static func prepareDatabase(db: Database, keyFetcher: GRDBKeyFetcher) throws {
        let key = try keyFetcher.fetchString()
        try db.execute(sql: "PRAGMA key = \"\(key)\"")
        try db.execute(sql: "PRAGMA cipher_plaintext_header_size = 32")
        try db.execute(sql: "PRAGMA checkpoint_fullfsync = ON")
        try SqliteUtil.setBarrierFsync(db: db, enabled: true)

        if !CurrentAppContext().isMainApp {
            let perConnectionCacheSizeInKibibytes = 2000 / (GRDBStorage.maximumReaderCountInExtensions + 1)
            // Limit the per-connection cache size based on the number of possible readers.
            // (The default is 2000KiB per connection regardless of how many other connections there are).
            // The minus sign indicates that this is in KiB rather than the database's page size.
            // An alternative would be to use SQLite's "shared cache" mode to have a single memory pool,
            // but unfortunately that changes the locking model in a way GRDB doesn't support.
            try db.execute(sql: "PRAGMA cache_size = -\(perConnectionCacheSizeInKibibytes)")
        }
    }
}

// MARK: - Directory Swaps

@available(iOSApplicationExtension, unavailable)
extension GRDBDatabaseStorageAdapter {
    public static var hasAssignedTransferDirectory: Bool { DirectoryMode.storedTransferFolderName != nil }

    /// This should be called during restoration to set up a staging database directory name
    /// Once a transfer directory has been written to, it's a fatal error to call this again until restoration has completed and `promoteTransferDirectoryToPrimary` is called
    public static func createNewTransferDirectory() {
        // A bit of a preamble to make sure we're not clearing out important data.
        if hasAssignedTransferDirectory {
            Logger.warn("Transfer directory already assigned a name. Verifying it contains no data...")
            let transferDatabaseDir = databaseDirUrl(directoryMode: .transfer)
            var isDirectory: ObjCBool = false

            // We're already in an unexpected (but recoverable) state. However if the currently active transfer
            // path is a file or a non-empty directory, we're too close to losing data and we should fail.
            if FileManager.default.fileExists(atPath: transferDatabaseDir.path, isDirectory: &isDirectory) {
                owsPrecondition(isDirectory.boolValue)
                owsPrecondition(try! FileManager.default.contentsOfDirectory(atPath: transferDatabaseDir.path).isEmpty)
            }
            OWSFileSystem.deleteFileIfExists(transferDatabaseDir.path)
            clearTransferDirectory()
        }

        DirectoryMode.updateTransferDirectoryName()
        Logger.info("Established new transfer directory: \(String(describing: DirectoryMode.transfer.folderName))")

        // Double check everything turned out okay. These should never happen, but if it does we can recover by trying again.
        if DirectoryMode.transfer.folderName == DirectoryMode.primary.folderName || DirectoryMode.transfer.folderName == nil {
            owsFailDebug("Unexpected transfer name. Primary: \(DirectoryMode.primary.folderName ?? "nil"). Transfer: \(DirectoryMode.primary.folderName ?? "nil")")
            clearTransferDirectory()
            createNewTransferDirectory()
        }
    }

    public static func promoteTransferDirectoryToPrimary() {
        owsPrecondition(CurrentAppContext().isMainApp, "Only the main app can swap databases")

        // Ordering matters here. We should be able to crash and recover without issue
        // A prior run may have already performed the swap but crashed, so we should not expect a transfer folder
        if let newPrimaryName = DirectoryMode.transfer.folderName {
            Self.writeStoredPrimaryFolderName(newPrimaryName)
            Logger.info("Updated primary database directory to: \(newPrimaryName)")
            clearTransferDirectory()
        }
    }

    private static func clearTransferDirectory() {
        if hasAssignedTransferDirectory, DirectoryMode.primary.folderName != DirectoryMode.transfer.folderName {
            do {
                let transferDirectoryUrl = databaseDirUrl(directoryMode: .transfer)
                Logger.info("Deleting contents of \(transferDirectoryUrl)")
                try OWSFileSystem.deleteFileIfExists(url: transferDirectoryUrl)
            } catch {
                // Unexpected, but not unrecoverable. Orphan data cleaner can take care of this since we're clearing the folder name
                owsFailDebug("Failed to reset transfer directory: \(error)")
            }
        }
        DirectoryMode.storedTransferFolderName = nil
        Logger.info("Finished resetting database transfer directory")
    }

    // Removes all directories with the common prefix that aren't the current primary GRDB directory
    public static func removeOrphanedGRDBDirectories() {
        allGRDBDirectories
            .filter { $0 != databaseDirUrl(directoryMode: .primary) }
            .forEach {
                do {
                    Logger.info("Deleting: \($0)")
                    try OWSFileSystem.deleteFileIfExists(url: $0)
                } catch {
                    owsFailDebug("Failed to delete: \($0). Error: \(error)")
                }
            }
    }
}

// MARK: -

extension GRDBDatabaseStorageAdapter {

#if TESTABLE_BUILD
    // TODO: We could eventually eliminate all nested transactions.
    private static let detectNestedTransactions = false

    // In debug builds, we can detect transactions opened within transaction.
    // These checks can also be used to detect unexpected "sneaky" transactions.
    @ThreadBacked(key: "canOpenTransaction", defaultValue: true)
    public static var canOpenTransaction: Bool
#endif

    @discardableResult
    public func read<T>(block: (DBReadTransaction) throws -> T) throws -> T {

#if TESTABLE_BUILD
        owsAssertDebug(Self.canOpenTransaction)
        // Check for nested tractions.
        if Self.detectNestedTransactions {
            // Check for nested tractions.
            Self.canOpenTransaction = false
        }
        defer {
            if Self.detectNestedTransactions {
                Self.canOpenTransaction = true
            }
        }
#endif

        return try pool.read { database in
            try autoreleasepool {
                try block(DBReadTransaction(database: database))
            }
        }
    }

    public func read(block: (DBReadTransaction) -> Void) throws {

#if TESTABLE_BUILD
        owsAssertDebug(Self.canOpenTransaction)
        if Self.detectNestedTransactions {
            // Check for nested tractions.
            Self.canOpenTransaction = false
        }
        defer {
            if Self.detectNestedTransactions {
                Self.canOpenTransaction = true
            }
        }
#endif

        try pool.read { database in
            autoreleasepool {
                block(DBReadTransaction(database: database))
            }
        }
    }

    public func writeWithTxCompletion(block: (DBWriteTransaction) -> Database.TransactionCompletion) throws {
#if TESTABLE_BUILD
        owsAssertDebug(Self.canOpenTransaction)
        // Check for nested tractions.
        if Self.detectNestedTransactions {
            // Check for nested tractions.
            Self.canOpenTransaction = false
        }
        defer {
            if Self.detectNestedTransactions {
                Self.canOpenTransaction = true
            }
        }
#endif

        var txCompletionBlocks: [DBWriteTransaction.CompletionBlock]!

        let counter = checkpointState.update {
            $0.workItem?.cancel()
            $0.workItem = nil
            $0.counter += 1
            return $0.counter
        }

        try pool.writeWithoutTransaction { database in
            try database.inTransaction { () -> Database.TransactionCompletion in
                return autoreleasepool {
                    let tx = DBWriteTransaction(database: database)
                    defer {
                        tx.finalizeTransaction()
                        txCompletionBlocks = tx.completionBlocks
                    }

                    return block(tx)
                }
            }
        }

        for block in txCompletionBlocks {
            block()
        }

        checkpointState.update {
            guard $0.counter == counter else {
                return
            }
            $0.workItem?.cancel()
            $0.workItem = scheduleCheckpoint(counter: counter)
            if $0.backgroundTask == nil {
                $0.backgroundTask = OWSBackgroundTask(label: "database checkpoint")
            }
        }
    }

    private func scheduleCheckpoint(counter: Int) -> DispatchWorkItem {
        let checkpointBlock = DispatchWorkItem { [weak self] in
            self?.tryToCheckpoint(counter: counter)
        }
        checkpointQueue.asyncAfter(deadline: .now() + .milliseconds(750), execute: checkpointBlock)
        return checkpointBlock
    }

    private func tryToCheckpoint(counter: Int) {
        // What Is Checkpointing?
        //
        // Checkpointing is the process of integrating the WAL into the main
        // database file. Without it, the WAL will grow indefinitely. A large WAL
        // affects read performance. Therefore we want to keep the WAL small.
        //
        // The SQLite WAL consists of "frames", representing changes to the
        // database. Frames are appended to the tail of the WAL. The WAL tracks how
        // many of its frames have been integrated into the database.
        //
        // Checkpointing entails some subset of the following tasks:
        //
        // - Integrating some or all of the frames of the WAL into the database.
        //
        // - "Restarting" the WAL so the next frame is written to the head of the
        // WAL file, not the tail. The WAL file size doesn't change, but since
        // subsequent writes overwrite from the start of the WAL, WAL file size
        // growth can be bounded.
        //
        // - "Truncating" the WAL so that that the WAL file is deleted or returned
        // to an empty state.
        //
        // The more unintegrated frames there are in the WAL, the longer a
        // checkpoint takes to complete. Long-running checkpoints can cause
        // problems in the app, e.g. blocking the main thread (note: we currently
        // do _NOT_ checkpoint on the main thread). Therefore we want to bound
        // overall WAL file size _and_ the number of unintegrated frames.
        //
        // To bound WAL file size, it's important to periodically "restart" or
        // (preferably) truncate the WAL file. We currently always truncate.
        //
        // To bound the number of unintegrated frames, we can use passive
        // checkpoints. We don't explicitly initiate passive checkpoints, but leave
        // this to SQLite auto-checkpointing.
        //
        // Checkpoint Types
        //
        // Checkpointing has several flavors: passive, full, restart, truncate.
        //
        // - Passive checkpoints abort immediately if there are any database
        // readers or writers. This makes them "cheap" in the sense that they won't
        // block for long. However they only integrate WAL contents; they don't
        // "restart" or "truncate", so they don't inherently limit WAL growth. My
        // understanding is that they can have partial success, e.g. integrating
        // some but not all of the frames of the WAL. This is beneficial.
        //
        // - Full/Restart/Truncate checkpoints will block using the busy-handler.
        // We use truncate checkpoints since they truncate the WAL file. See
        // GRDBStorage.buildConfiguration for our busy-handler (aka busyMode
        // callback). It aborts after ~50ms. These checkpoints are more expensive
        // and will block while they do their work but will limit WAL growth.
        //
        // SQLite has auto-checkpointing enabled by default, meaning that it is
        // continually trying to perform passive checkpoints in the background.
        // This is beneficial.
        //
        // Exclusion
        //
        // Note that we are navigating multiple exclusion mechanisms.
        //
        // - SQLite (as we have configured it) excludes database writes using write
        // locks (POSIX advisory locking on the database files). This locking
        // protects the database from cross-process writes.
        //
        // - GRDB writers use a serial DispatchQueue to exclude writes from each
        // other within a given DatabasePool / DatabaseQueue. AFAIK this does not
        // protect any GRDB internal state; it allows GRDB to detect re-entrancy,
        // etc.
        //
        // SQLite cannot checkpoint if there are any readers or writers. Therefore
        // we cannot checkpoint within a SQLite write transaction. We checkpoint
        // after write transactions using DatabasePool.writeWithoutTransaction().
        // This method uses the GRDB exclusion mechanism but not the SQL one.
        //
        // Our approach:
        //
        // - Always (not including auto-checkpointing) use truncate checkpoints to
        // limit WAL size.
        //
        // What could go wrong:
        //
        // - Checkpointing could be expensive in some cases, causing blocking. This
        // shouldn't be an issue: we're more aggressive than ever about keeping the
        // WAL small.
        //
        // - Cross-process activity could interfere with checkpointing. This
        // shouldn't be an issue: We shouldn't have more than one of the apps (main
        // app, SAE, NSE) active at the same time for long.
        //
        // - Checkpoints might frequently fail if we're constantly doing reads.
        // This shouldn't be an issue: A checkpoint should eventually succeed when
        // db activity settles. This checkpoint might take a while but that's
        // unavoidable. The counter-argument is that we only try to checkpoint
        // immediately after a write. We often do reads immediately after writes to
        // update the UI to reflect the DB changes. Those reads _might_ frequently
        // interfere with checkpointing.
        //
        // - We might not be checkpointing often enough, or we might be
        // checkpointing too often. Either way, it's about balancing overall perf
        // with the perf cost of the next successful checkpoint.
        //
        // Reference
        //
        // * https://www.sqlite.org/c3ref/wal_checkpoint_v2.html
        // * https://www.sqlite.org/wal.html
        // * https://www.sqlite.org/howtocorrupt.html
        assertOnQueue(checkpointQueue)

        // Set checkpointTimeout flag.
        owsAssertDebug(GRDBStorage.checkpointTimeout == nil)
        GRDBStorage.checkpointTimeout = GRDBStorage.maxBusyTimeoutMs
        owsAssertDebug(GRDBStorage.checkpointTimeout != nil)
        defer {
            // Clear checkpointTimeout flag.
            owsAssertDebug(GRDBStorage.checkpointTimeout != nil)
            GRDBStorage.checkpointTimeout = nil
            owsAssertDebug(GRDBStorage.checkpointTimeout == nil)
        }

        pool.writeWithoutTransaction { database in
            let (shouldCheckpoint, backgroundTask) = checkpointState.update {
                let shouldCheckpoint = $0.counter == counter
                var backgroundTask: OWSBackgroundTask?
                if shouldCheckpoint {
                    backgroundTask = $0.backgroundTask.take()
                }
                return (shouldCheckpoint, backgroundTask)
            }
            defer {
                backgroundTask?.end()
            }
            guard shouldCheckpoint else {
                Logger.warn("skipping checkpoint that's been canceled")
                return
            }
            guard database.sqliteConnection != nil else {
                Logger.warn("skipping checkpoint for database that's already closed.")
                return
            }
            let timedResult = withDuration { _ = try database.checkpoint(.truncate) }
            if timedResult.duration > 0.25 {
                Logger.warn("slow checkpoint: \(timedResult.formattedDuration)")
            }
            do {
                try timedResult.value.get()
                if DebugFlags.internalLogging {
                    Logger.info("checkpointed w/counter \(counter) in \(timedResult.formattedDuration)")
                }
            } catch {
                if (error as? DatabaseError)?.resultCode == .SQLITE_BUSY {
                    // It is expected that the busy-handler (aka busyMode callback)
                    // will abort checkpoints if there is contention.
                } else {
                    owsFailDebug("couldn't checkpoint: \(error.grdbErrorForLogging)")
                }
            }
        }
    }
}

// MARK: -

func filterForDBQueryLog(_ input: String) -> String {
    var result = input
    while let matchRange = result.range(of: "x'[0-9a-f\n]*'", options: .regularExpression) {
        let charCount = result.distance(from: matchRange.lowerBound, to: matchRange.upperBound)
        let byteCount = Int64(charCount) / 2
        let formattedByteCount = ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .memory)
        result = result.replacingCharacters(in: matchRange, with: "x'<\(formattedByteCount)>'")
    }
    return result
}

private func dbQueryLog(_ value: String) {
    let filteredValue = filterForDBQueryLog(value)

    // Remove any newlines/leading space to put the log message on a single line
    let re = try! NSRegularExpression(pattern: #"\n *"#, options: [])
    let finalValue = re.stringByReplacingMatches(
        in: filteredValue,
        range: filteredValue.entireRange,
        withTemplate: " ",
    )

    Logger.debug(finalValue)
}

// MARK: -

private struct GRDBStorage {

    let pool: DatabasePool

    private let dbURL: URL
    private let poolConfiguration: Configuration

    fileprivate static let maxBusyTimeoutMs = 50

    init(dbURL: URL, keyFetcher: GRDBKeyFetcher) throws {
        self.dbURL = dbURL

        self.poolConfiguration = Self.buildConfiguration(keyFetcher: keyFetcher)
        self.pool = try Self.buildPool(dbURL: dbURL, poolConfiguration: poolConfiguration)

        OWSFileSystem.protectFileOrFolder(atPath: dbURL.path)
    }

    // See: https://github.com/groue/GRDB.swift/blob/master/Documentation/SharingADatabase.md
    private static func buildPool(dbURL: URL, poolConfiguration: Configuration) throws -> DatabasePool {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinatorError: NSError?
        var newPool: DatabasePool?
        var dbError: Error?
        coordinator.coordinate(
            writingItemAt: dbURL,
            options: .forMerging,
            error: &coordinatorError,
            byAccessor: { url in
                do {
                    newPool = try DatabasePool(path: url.path, configuration: poolConfiguration)
                } catch {
                    dbError = error
                }
            },
        )
        if let error = dbError ?? coordinatorError {
            throw error
        }
        guard let pool = newPool else {
            throw OWSAssertionError("Missing pool.")
        }
        return pool
    }

    // The checkpointTimeout flag is backed by a thread local.
    // We don't want to affect the behavior of the busy-handler (aka busyMode callback)
    // in other threads while checkpointing.
    fileprivate static var checkpointTimeoutKey: String { "GRDBStorage.checkpointTimeoutKey" }
    fileprivate static var checkpointTimeout: Int? {
        get {
            Thread.current.threadDictionary[Self.checkpointTimeoutKey] as? Int
        }
        set {
            Thread.current.threadDictionary[Self.checkpointTimeoutKey] = newValue
        }
    }

    fileprivate static var maximumReaderCountInExtensions: Int { 4 }

    private static func buildConfiguration(keyFetcher: GRDBKeyFetcher) -> Configuration {
        var configuration = Configuration()
        configuration.readonly = false
        configuration.foreignKeysEnabled = true // Default is already true

#if DEBUG
        configuration.publicStatementArguments = true
#endif

        // TODO: We should set this to `false` (or simply remove this line, as `false` is the default).
        // Historically, we took advantage of SQLite's old permissive behavior, but the SQLite
        // developers [regret this][0] and may change it in the future.
        //
        // [0]: https://sqlite.org/quirks.html#dblquote
        configuration.acceptsDoubleQuotedStringLiterals = true

        // Useful when your app opens multiple databases
        configuration.label = "GRDB Storage"
        let isMainApp = CurrentAppContext().isMainApp
        configuration.maximumReaderCount = isMainApp ? 10 : maximumReaderCountInExtensions
        configuration.busyMode = .callback({ (retryCount: Int) -> Bool in
            // sleep N milliseconds
            let millis = 25
            usleep(useconds_t(millis * 1000))
            let accumulatedWaitMs = millis * (retryCount + 1)
            if accumulatedWaitMs > 0, (accumulatedWaitMs % 250) == 0 {
                Logger.warn("Database busy for \(accumulatedWaitMs)ms")
            }

            // Only time out during checkpoints, not writes.
            if let checkpointTimeout = self.checkpointTimeout {
                if accumulatedWaitMs > checkpointTimeout {
                    return false
                }
                return true
            } else {
                return true
            }
        })
        configuration.prepareDatabase { db in
            try GRDBDatabaseStorageAdapter.prepareDatabase(db: db, keyFetcher: keyFetcher)

#if DEBUG
#if false
            db.trace { dbQueryLog("\($0)") }
#endif
#endif
        }
        configuration.defaultTransactionKind = .immediate
        configuration.allowsUnsafeTransactions = true
        configuration.automaticMemoryManagement = false
        return configuration
    }
}

// MARK: -

public struct GRDBKeyFetcher {

    public enum Constants {
        fileprivate static let keyServiceName: String = "GRDBKeyChainService"
        fileprivate static let keyName: String = "GRDBDatabaseCipherKeySpec"
        // 256 bit key + 128 bit salt
        public static let kSQLCipherKeySpecLength: Int32 = 48
    }

    private let keychainStorage: any KeychainStorage

    public init(keychainStorage: any KeychainStorage) {
        self.keychainStorage = keychainStorage
    }

    func fetchString() throws -> String {
        // Use a raw key spec, where the 96 hexadecimal digits are provided
        // (i.e. 64 hex for the 256 bit key, followed by 32 hex for the 128 bit salt)
        // using explicit BLOB syntax, e.g.:
        //
        // x'98483C6EB40B6C31A448C22A66DED3B5E5E8D5119CAC8327B655C8B5C483648101010101010101010101010101010101'
        let data = try fetchData()

        guard data.count == Constants.kSQLCipherKeySpecLength else {
            owsFail("unexpected keyspec length")
        }

        let passphrase = "x'\(data.hexadecimalString)'"
        return passphrase
    }

    public func fetchData() throws -> Data {
        return try keychainStorage.dataValue(service: Constants.keyServiceName, key: Constants.keyName)
    }

    public func clear() throws {
        try keychainStorage.removeValue(service: Constants.keyServiceName, key: Constants.keyName)
    }

    func generateAndStore() throws {
        let keyData = Randomness.generateRandomBytes(UInt(Constants.kSQLCipherKeySpecLength))
        try store(data: keyData)
    }

    public func store(data: Data) throws {
        guard data.count == Constants.kSQLCipherKeySpecLength else {
            owsFail("unexpected keyspec length")
        }
        try keychainStorage.setDataValue(data, service: Constants.keyServiceName, key: Constants.keyName)
    }

    /// Fetches the GRDB key data from the keychain.
    /// - Note: Will fatally assert if not running in a debug or test build.
    /// - Returns: The key data, if available.
    public func debugOnly_keyData() -> Data? {
        owsPrecondition(DebugFlags.internalSettings)
        return try? fetchData()
    }
}

// MARK: -

private extension URL {
    func appendingPathString(_ string: String) -> URL? {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.path += string
        return components.url
    }
}

extension GRDBDatabaseStorageAdapter {
    public static func walFileUrl(for databaseFileUrl: URL) -> URL {
        guard let result = databaseFileUrl.appendingPathString("-wal") else {
            owsFail("Could not get WAL URL")
        }
        return result
    }

    public static func shmFileUrl(for databaseFileUrl: URL) -> URL {
        guard let result = databaseFileUrl.appendingPathString("-shm") else {
            owsFail("Could not get SHM URL")
        }
        return result
    }

    public var databaseFilePath: String {
        return databaseFileUrl.path
    }

    public var databaseWALFilePath: String {
        Self.walFileUrl(for: databaseFileUrl).path
    }

    public var databaseSHMFilePath: String {
        Self.shmFileUrl(for: databaseFileUrl).path
    }

    static func removeAllFiles() {
        // First, delete our primary database
        let databaseUrl = GRDBDatabaseStorageAdapter.databaseFileUrl()
        OWSFileSystem.deleteFileIfExists(databaseUrl.path)
        OWSFileSystem.deleteFileIfExists(databaseUrl.path + "-wal")
        OWSFileSystem.deleteFileIfExists(databaseUrl.path + "-shm")

        // In the spirit of thoroughness, since we're deleting all of our data anyway, let's
        // also delete every item in our container directory with the "grdb" prefix just in
        // case we have a leftover database directory from a prior restoration.
        allGRDBDirectories.forEach {
            do {
                try OWSFileSystem.deleteFileIfExists(url: $0)
            } catch {
                owsFailDebug("Failed to delete: \($0). Error: \(error)")
            }
        }
    }

    /// A list of the URLs for every GRDB directory, both primary and orphaned
    /// Returns all directories with the DirectoryMode.commonGRDBPrefix in the database base directory
    static var allGRDBDirectories: [URL] {
        let containerDirectory = SDSDatabaseStorage.baseDir
        let containerPathItems: [String]
        do {
            containerPathItems = try FileManager.default.contentsOfDirectory(atPath: containerDirectory.path)
        } catch {
            owsFailDebug("Failed to fetch other directory items: \(error)")
            containerPathItems = []
        }

        return containerPathItems
            .filter { $0.hasPrefix(DirectoryMode.commonGRDBPrefix) }
            .map { containerDirectory.appendingPathComponent($0) }
    }

    /// Run database integrity checks and log their results.
    public static func checkIntegrity(databaseStorage: SDSDatabaseStorage) -> SqliteUtil.IntegrityCheckResult {
        func read<T>(block: (Database) -> T) -> T {
            return databaseStorage.read { block($0.database) }
        }
        func write<T>(block: (Database) -> T) -> T {
            return databaseStorage.write { block($0.database) }
        }

        read { db in
            Logger.info("PRAGMA cipher_provider")
            Logger.info(SqliteUtil.cipherProvider(db: db))
        }

        let cipherIntegrityCheckResult = read { db in
            Logger.info("PRAGMA cipher_integrity_check")
            return SqliteUtil.cipherIntegrityCheck(db: db)
        }

        let quickCheckResult = write { db in
            Logger.info("PRAGMA quick_check")
            return SqliteUtil.quickCheck(db: db)
        }

        return cipherIntegrityCheckResult && quickCheckResult
    }
}

// MARK: - Reporting

extension GRDBDatabaseStorageAdapter {
    var databaseFileSize: UInt64 {
        return (try? OWSFileSystem.fileSize(ofPath: databaseFilePath)) ?? 0
    }

    var databaseWALFileSize: UInt64 {
        return (try? OWSFileSystem.fileSize(ofPath: databaseWALFilePath)) ?? 0
    }

    var databaseSHMFileSize: UInt64 {
        return (try? OWSFileSystem.fileSize(ofPath: databaseSHMFilePath)) ?? 0
    }
}

// MARK: - Checkpoints

extension GRDBDatabaseStorageAdapter {
    public func syncTruncatingCheckpoint() throws {
        try GRDBDatabaseStorageAdapter.checkpoint(pool: pool)
    }

    private static func checkpoint(pool: DatabasePool) throws {
        try Bench(title: "Slow checkpoint", logIfLongerThan: 0.01, logInProduction: true) {
            // Set checkpointTimeout flag.
            // If we hit the timeout, we get back SQLITE_BUSY, which is ignored below.
            owsAssertDebug(GRDBStorage.checkpointTimeout == nil)
            GRDBStorage.checkpointTimeout = 3000 // 3s
            owsAssertDebug(GRDBStorage.checkpointTimeout != nil)
            defer {
                // Clear checkpointTimeout flag.
                owsAssertDebug(GRDBStorage.checkpointTimeout != nil)
                GRDBStorage.checkpointTimeout = nil
                owsAssertDebug(GRDBStorage.checkpointTimeout == nil)
            }

#if TESTABLE_BUILD
            let startTime = CACurrentMediaTime()
#endif
            try pool.writeWithoutTransaction { db in
#if TESTABLE_BUILD
                let startElapsedSeconds: TimeInterval = CACurrentMediaTime() - startTime
                let slowStartSeconds: TimeInterval = TimeInterval(GRDBStorage.maxBusyTimeoutMs) / 1000
                if startElapsedSeconds > slowStartSeconds * 2 {
                    // maxBusyTimeoutMs isn't a hard limit, but slow starts should be very rare.
                    let formattedTime = String(format: "%0.2fms", startElapsedSeconds * 1000)
                    owsFailDebug("Slow checkpoint start: \(formattedTime)")
                }
#endif

                do {
                    try db.checkpoint(.truncate)
                    Logger.info("Truncating checkpoint succeeded")
                } catch {
                    if (error as? DatabaseError)?.resultCode == .SQLITE_BUSY {
                        // Busy is not an error.
                        Logger.info("Truncating checkpoint failed due to busy")
                    } else {
                        throw error
                    }
                }
            }
        }
    }
}

// MARK: -

public struct ConstraintError: Error {
}

extension GRDB.DatabaseError {
    public var forLogging: Self {
        // DatabaseError.description includes the arguments.
        Logger.verbose("grdbError: \(self))")
        // DatabaseError.description does not include the extendedResultCode.
        Logger.verbose("resultCode: \(self.resultCode), extendedResultCode: \(self.extendedResultCode), message: \(String(describing: self.message)), sql: \(String(describing: self.sql))")
        return Self(
            resultCode: self.extendedResultCode,
            message: "\(String(describing: self.message)) (extended result code: \(self.extendedResultCode.rawValue))",
            sql: nil,
            arguments: nil,
        )
    }
}

extension Error {
    public var grdbErrorForLogging: any Error {
        // If not a GRDB error, return unmodified.
        return (self as? GRDB.DatabaseError)?.forLogging ?? self
    }

    public func forceCastToDatabaseError() -> DatabaseError {
        switch self {
        case let error as GRDB.DatabaseError:
            return error.forLogging
        default:
            owsFailDebug("The database threw a non-DatabaseError: \(self)")
            return DatabaseError(
                resultCode: .SQLITE_ERROR,
                message: "\(self)",
                sql: nil,
                arguments: nil,
            )
        }
    }
}
