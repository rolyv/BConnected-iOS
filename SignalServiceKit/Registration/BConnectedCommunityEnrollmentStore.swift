// Copyright 2026 BConnected contributors. SPDX-License-Identifier: AGPL-3.0-only
import Foundation

final class BConnectedCommunityEnrollmentStore: BConnectedCommunityPersistence {
    private let db: any DB
    private let values = KeyValueStore(collection: "BConnectedCommunityEnrollment.v1")
    init(db: any DB) { self.db = db }
    func transaction<T>(_ update: (inout BConnectedCommunityRecord) throws -> T) throws -> T {
        try db.writeWithRollbackIfThrows { tx in
            var record: BConnectedCommunityRecord
            do {
                if let data = values.getData("session", transaction: tx) { record = try JSONDecoder().decode(BConnectedCommunityRecord.self, from: data) }
                else { record = .init() }
                try record.validate()
            } catch { throw BConnectedEnrollmentError.persistenceUnavailable }
            let result = try update(&record)
            do { try record.validate(); values.setData(try JSONEncoder().encode(record), key: "session", transaction: tx) }
            catch { throw BConnectedEnrollmentError.persistenceUnavailable }
            return result
        }
    }
}
extension BConnectedCommunityEnrollmentCoordinator {
    public convenience init(db: any DB, endpoint: BConnectedEnrollmentEndpoint, enrollment: BConnectedEnrollmentCoordinator) {
        self.init(persistence: BConnectedCommunityEnrollmentStore(db: db), client: BConnectedCommunityClient(endpoint: endpoint), enrollment: enrollment)
    }
}
