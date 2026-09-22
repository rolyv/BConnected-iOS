// Copyright 2026 BConnected contributors. SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Uses the same SQLCipher app DB already used by RegistrationCoordinator before registration.
/// A separate collection prevents upstream cancellation/reset from erasing possibly committed keys.
final class BConnectedEnrollmentStore: BConnectedEnrollmentPersistence {
    private let db: any DB
    private let values = KeyValueStore(collection: "BConnectedEnrollment.v1")
    private let nativeInstaller: BConnectedNativeAccountInstaller?
    init(db: any DB, nativeInstaller: BConnectedNativeAccountInstaller? = nil) {
        self.db = db; self.nativeInstaller = nativeInstaller
    }
    var supportsNativeInstallation: Bool { nativeInstaller != nil }

    func installNativeAccount(expected: BConnectedEnrollmentRecord, account: BConnectedEnrollmentObservation.Account) throws {
        guard let nativeInstaller else { throw BConnectedEnrollmentError.unavailable }
        try db.writeWithRollbackIfThrows { tx in
            guard let bytes = values.getData("attempt", transaction: tx) else { throw BConnectedEnrollmentError.missingAttempt }
            var record: BConnectedEnrollmentRecord
            let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
            do {
                record = try JSONDecoder().decode(BConnectedEnrollmentRecord.self, from: bytes)
                try record.validate()
                guard try encoder.encode(record) == encoder.encode(expected) else { throw BConnectedEnrollmentError.immutableConflict }
            } catch { throw BConnectedEnrollmentError.persistenceUnavailable }
            guard record.observation?.state == .active, record.observation?.registrationAuthorized == true,
                  record.observation?.account == account else { throw BConnectedEnrollmentError.immutableConflict }
            let install = try nativeInstaller.prepare(record: record, account: account, tx: tx)
            let repeated = record.installedAccount != nil
            record.installedAccount = account
            try record.validate()
            let encoded: Data
            do { encoded = try encoder.encode(record) }
            catch { throw BConnectedEnrollmentError.persistenceUnavailable }
            // No recoverable/throwing operation follows the first mutation. GRDB/KeyValueStore
            // fail closed on database I/O failure; the encompassing SQLite transaction is atomic.
            install()
            if !repeated { values.setData(encoded, key: "attempt", transaction: tx) }
        }
    }

    func transaction<T>(_ update: (inout BConnectedEnrollmentRecord?) throws -> T) throws -> T {
        try db.writeWithRollbackIfThrows { tx in
            var record: BConnectedEnrollmentRecord?
            do {
                if let bytes = values.getData("attempt", transaction: tx) {
                    record = try JSONDecoder().decode(BConnectedEnrollmentRecord.self, from: bytes)
                }
                try record?.validate()
            } catch { throw BConnectedEnrollmentError.persistenceUnavailable }
            let existed = record != nil
            let result = try update(&record)
            do {
                guard let record else {
                    guard !existed else { throw BConnectedEnrollmentError.persistenceUnavailable }
                    return result
                }
                try record.validate()
                let bytes = try JSONEncoder().encode(record)
                values.setData(bytes, key: "attempt", transaction: tx)
            } catch { throw BConnectedEnrollmentError.persistenceUnavailable }
            return result
        }
    }
}

extension BConnectedEnrollmentCoordinator {
    /// Construction has no network effects and does not mark the upstream registration complete.
    public convenience init(db: any DB, endpoint: BConnectedEnrollmentEndpoint, nativeInstaller: BConnectedNativeAccountInstaller? = nil) {
        self.init(persistence: BConnectedEnrollmentStore(db: db, nativeInstaller: nativeInstaller), client: BConnectedEnrollmentClient(endpoint: endpoint))
    }
}
