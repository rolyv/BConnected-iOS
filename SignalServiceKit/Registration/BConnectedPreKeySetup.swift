// Copyright 2026 BConnected contributors. SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import LibSignalClient

/// Pending-device batches only. Every call belongs to the caller's SQLCipher rollback transaction
/// after native account/profile/entropy validation. No network, rotation or readiness side effects.
enum BConnectedPreKeySetup {
    static func prepare(record: BConnectedEnrollmentRecord, preKeyStore: PreKeyStore,
                        tx: DBWriteTransaction) throws -> BConnectedEnrollmentRecord {
        try record.validate()
        try requireStored(record, tx: tx)
        guard record.publication?.complete == true else { throw BConnectedEnrollmentError.immutableConflict }
        if record.preKeyPublication != nil {
            try validateNative(record, preKeyStore: preKeyStore, tx: tx)
            return record
        }
        // A receipt-free but populated pool is a conflict, never permission to replace local keys.
        try validateNative(record, preKeyStore: preKeyStore, tx: tx)
        func generate(_ identity: OWSIdentity, _ saved: BConnectedEnrollmentRecord.Identity) throws -> BConnectedEnrollmentRecord.PreKeyPublication.Batch {
            let ecStore = PreKeyStoreImpl(for: identity, preKeyStore: preKeyStore)
            let pqStore = KyberPreKeyStoreImpl(for: identity, dateProvider: { Date() }, preKeyStore: preKeyStore)
            let ec = PreKeyStoreImpl.generatePreKeyRecords(forPreKeyIds: ecStore.allocatePreKeyIds(tx: tx))
            let pq = pqStore.generatePreKeyRecords(forPreKeyIds: pqStore.allocatePreKeyIds(count: 100, tx: tx),
                signedBy: try IdentityKeyPair(bytes: saved.pair).privateKey)
            let batch = BConnectedEnrollmentRecord.PreKeyPublication.Batch(ec: ec.map { $0.serialize() }, pq: pq.map { $0.serialize() },
                request: try BConnectedEnrollmentRecord.PreKeyPublication.Batch.request(ec: ec.map { $0.serialize() }, pq: pq.map { $0.serialize() }, identity: saved))
            ecStore.storePreKeyRecords(ec, tx: tx)
            pqStore.storePreKeyRecords(pq, isLastResort: false, tx: tx)
            return batch
        }
        var record = record
        record.preKeyPublication = .init(version: 1, contextHash: try record.preKeyContextHash(),
            aci: try generate(.aci, record.aci), pni: try generate(.pni, record.pni))
        try record.validate()
        try validateNative(record, preKeyStore: preKeyStore, tx: tx)
        try save(record, tx: tx)
        return record
    }

    static func transition(record: BConnectedEnrollmentRecord, expected: BConnectedEnrollmentRecord,
                           identity: BConnectedPreKeyIdentity, acknowledge: Bool,
                           preKeyStore: PreKeyStore, tx: DBWriteTransaction) throws -> BConnectedEnrollmentRecord {
        try record.validate()
        try requireStored(record, tx: tx)
        guard try encoded(record) == encoded(expected), var keys = record.preKeyPublication,
              identity != .pni || keys.aci.state == .acknowledged,
              keys.batch(identity).state == (acknowledge ? .dispatched : .prepared) else { throw BConnectedEnrollmentError.immutableConflict }
        try validateNative(record, preKeyStore: preKeyStore, tx: tx)
        if identity == .aci { keys.aci.state = acknowledge ? .acknowledged : .dispatched }
        else { keys.pni.state = acknowledge ? .acknowledged : .dispatched }
        var record = record; record.preKeyPublication = keys
        try record.validate()
        try save(record, tx: tx)
        return record
    }

    static func validateNative(_ record: BConnectedEnrollmentRecord, preKeyStore: PreKeyStore, tx: DBReadTransaction) throws {
        for (identity, saved, batch) in [(OWSIdentity.aci, record.aci, record.preKeyPublication?.aci), (.pni, record.pni, record.preKeyPublication?.pni)] {
            let signed = try LibSignalClient.SignedPreKeyRecord(bytes: saved.signedPreKey)
            let lastResort = try LibSignalClient.KyberPreKeyRecord(bytes: saved.lastResortPreKey)
            var expected: [String: (Data, Bool)] = ["2:\(signed.id)": (saved.signedPreKey, false), "1:\(lastResort.id)": (saved.lastResortPreKey, false)]
            if let batch {
                for bytes in batch.ec { expected["0:\(try LibSignalClient.PreKeyRecord(bytes: bytes).id)"] = (bytes, true) }
                for bytes in batch.pq { expected["1:\(try LibSignalClient.KyberPreKeyRecord(bytes: bytes).id)"] = (bytes, true) }
                guard try PreKeyStoreImpl(for: identity, preKeyStore: preKeyStore).bconnectedLastAllocatedId(tx: tx) == LibSignalClient.PreKeyRecord(bytes: batch.ec.last!).id,
                      try KyberPreKeyStoreImpl(for: identity, dateProvider: { Date() }, preKeyStore: preKeyStore).bconnectedLastAllocatedId(tx: tx) == LibSignalClient.KyberPreKeyRecord(bytes: batch.pq.last!).id else {
                    throw BConnectedEnrollmentError.immutableConflict
                }
            }
            let actual = try preKeyStore.forIdentity(identity).bconnectedKeyRecords(tx: tx)
            guard actual.count == expected.count, actual.allSatisfy({ row in
                let value = expected["\(row.namespace.rawValue):\(row.keyId)"]
                return value?.0 == row.serializedRecord && value?.1 == row.isOneTime && row.replacedAt == nil
            }) else { throw BConnectedEnrollmentError.immutableConflict }
        }
    }

    private static func encoded(_ record: BConnectedEnrollmentRecord) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return try encoder.encode(record)
    }
    private static func requireStored(_ record: BConnectedEnrollmentRecord, tx: DBReadTransaction) throws {
        guard let bytes = KeyValueStore(collection: "BConnectedEnrollment.v1").getData("attempt", transaction: tx),
              try encoded(JSONDecoder().decode(BConnectedEnrollmentRecord.self, from: bytes)) == encoded(record) else {
            throw BConnectedEnrollmentError.immutableConflict
        }
    }
    private static func save(_ record: BConnectedEnrollmentRecord, tx: DBWriteTransaction) throws {
        KeyValueStore(collection: "BConnectedEnrollment.v1").setData(try encoded(record), key: "attempt", transaction: tx)
    }
}
