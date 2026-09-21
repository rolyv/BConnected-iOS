// Copyright 2026 BConnected contributors. SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Uses the same SQLCipher app DB already used by RegistrationCoordinator before registration.
/// A separate collection prevents upstream cancellation/reset from erasing possibly committed keys.
final class BConnectedEnrollmentStore: BConnectedEnrollmentPersistence {
    private let db: any DB
    private let values = KeyValueStore(collection: "BConnectedEnrollment.v1")
    init(db: any DB) { self.db = db }

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
    public convenience init(db: any DB, endpoint: BConnectedEnrollmentEndpoint) {
        self.init(persistence: BConnectedEnrollmentStore(db: db), client: BConnectedEnrollmentClient(endpoint: endpoint))
    }
}
