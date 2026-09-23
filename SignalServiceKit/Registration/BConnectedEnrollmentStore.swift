// Copyright 2026 BConnected contributors. SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import CryptoKit

/// Uses the same SQLCipher app DB already used by RegistrationCoordinator before registration.
/// A separate collection prevents upstream cancellation/reset from erasing possibly committed keys.
final class BConnectedEnrollmentStore: BConnectedEnrollmentPersistence {
    private let db: any DB
    private let values = KeyValueStore(collection: "BConnectedEnrollment.v1")
    private let nativeInstaller: BConnectedNativeAccountInstaller?
    private let accountKeyStore: AccountKeyStore?
    private let publicationConfiguration: BConnectedPublicationConfiguration?
    private let udManager: OWSUDManager?
    init(db: any DB, nativeInstaller: BConnectedNativeAccountInstaller? = nil, accountKeyStore: AccountKeyStore? = nil,
         publicationConfiguration: BConnectedPublicationConfiguration? = nil, udManager: OWSUDManager? = nil) {
        self.db = db; self.nativeInstaller = nativeInstaller; self.accountKeyStore = accountKeyStore
        self.publicationConfiguration = publicationConfiguration; self.udManager = udManager
    }
    var supportsNativeInstallation: Bool { nativeInstaller != nil }

    func validateAccountAcceptance(configuration: BConnectedPublicationConfiguration, expected: BConnectedEnrollmentRecord?) throws -> BConnectedEnrollmentRecord {
        guard let nativeInstaller else { throw BConnectedEnrollmentError.unavailable }
        return try db.writeWithRollbackIfThrows { tx in
            try BConnectedLocalAccountSetup.validateAccountAcceptance(configuration: configuration, expected: expected, tx: tx) {
                let current = try preparePublication(configuration: configuration, tx: tx)
                return try nativeInstaller.preparePreKeys(record: current, configuration: configuration, tx: tx)
            }
        }
    }

    private func preparePublication(configuration: BConnectedPublicationConfiguration, tx: DBWriteTransaction) throws -> BConnectedEnrollmentRecord {
        guard let nativeInstaller, let accountKeyStore, let udManager,
              publicationConfiguration?.hash == configuration.hash else { throw BConnectedEnrollmentError.unavailable }
        return try BConnectedLocalAccountSetup.preparePublication(tx: tx, configuration: configuration, accountKeyStore: accountKeyStore,
            sharePhoneNumber: udManager.phoneNumberSharingMode(tx: tx).orDefault == .everybody) { record, account, tx in
                _ = try nativeInstaller.prepare(record: record, account: account, tx: tx)
            }
    }

    func preparePublication(configuration: BConnectedPublicationConfiguration) throws -> BConnectedEnrollmentRecord {
        try db.writeWithRollbackIfThrows { try preparePublication(configuration: configuration, tx: $0) }
    }

    func transitionPublication(expected: BConnectedEnrollmentRecord, step: BConnectedPublicationStep, acknowledge: Bool) throws -> BConnectedEnrollmentRecord {
        guard let configuration = publicationConfiguration else { throw BConnectedEnrollmentError.unavailable }
        return try db.writeWithRollbackIfThrows { tx in
            let record = try preparePublication(configuration: configuration, tx: tx)
            return try BConnectedLocalAccountSetup.transitionPublication(record: record, expected: expected, step: step, acknowledge: acknowledge, tx: tx)
        }
    }

    func preparePreKeys(configuration: BConnectedPublicationConfiguration) throws -> BConnectedEnrollmentRecord {
        guard let nativeInstaller else { throw BConnectedEnrollmentError.unavailable }
        return try db.writeWithRollbackIfThrows { tx in
            let record = try preparePublication(configuration: configuration, tx: tx)
            return try nativeInstaller.preparePreKeys(record: record, configuration: configuration, tx: tx)
        }
    }

    func transitionPreKeys(expected: BConnectedEnrollmentRecord, identity: BConnectedPreKeyIdentity, acknowledge: Bool) throws -> BConnectedEnrollmentRecord {
        guard let nativeInstaller, let configuration = publicationConfiguration else { throw BConnectedEnrollmentError.unavailable }
        return try db.writeWithRollbackIfThrows { tx in
            let record = try preparePublication(configuration: configuration, tx: tx)
            return try nativeInstaller.transitionPreKeys(record: record, expected: expected, identity: identity, acknowledge: acknowledge, tx: tx)
        }
    }

    func prepareAccountEntropy() throws {
        guard let nativeInstaller, let accountKeyStore else { throw BConnectedEnrollmentError.unavailable }
        try db.writeWithRollbackIfThrows { tx in
            try BConnectedLocalAccountSetup.prepareAccountEntropy(tx: tx, accountKeyStore: accountKeyStore) { record, account, tx in
                _ = try nativeInstaller.prepare(record: record, account: account, tx: tx)
            }
        }
    }

    func prepareLocalAccount() throws {
        guard let nativeInstaller else { throw BConnectedEnrollmentError.unavailable }
        try BConnectedLocalAccountSetup.prepare(db: db) { record, account, tx in
            // An installed-account receipt forces the native validator's exact-repeat path.
            // Discard its no-op closure; this operation never reinstalls or rotates native keys.
            _ = try nativeInstaller.prepare(record: record, account: account, tx: tx)
        }
    }

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
            let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
            let original: Data?
            do { original = try record.map { try encoder.encode($0) } }
            catch { throw BConnectedEnrollmentError.persistenceUnavailable }
            let result = try update(&record)
            do {
                guard let record else {
                    guard !existed else { throw BConnectedEnrollmentError.persistenceUnavailable }
                    return result
                }
                try record.validate()
                let bytes = try encoder.encode(record)
                if bytes != original { values.setData(bytes, key: "attempt", transaction: tx) }
            } catch { throw BConnectedEnrollmentError.persistenceUnavailable }
            return result
        }
    }
}

extension BConnectedEnrollmentCoordinator {
    /// Construction has no network effects and does not mark the upstream registration complete.
    public convenience init(db: any DB, endpoint: BConnectedEnrollmentEndpoint, nativeInstaller: BConnectedNativeAccountInstaller? = nil, accountKeyStore: AccountKeyStore? = nil,
                            publicationConfiguration: BConnectedPublicationConfiguration? = nil, udManager: OWSUDManager? = nil) {
        self.init(persistence: BConnectedEnrollmentStore(db: db, nativeInstaller: nativeInstaller, accountKeyStore: accountKeyStore,
                  publicationConfiguration: publicationConfiguration, udManager: udManager), client: BConnectedEnrollmentClient(endpoint: endpoint),
                  publicationConfiguration: publicationConfiguration, publisher: publicationConfiguration.map { _ in BConnectedPublicationClient() },
                  preKeyPublisher: publicationConfiguration.map { _ in BConnectedPreKeyClient() },
                  acceptanceReader: publicationConfiguration.map { _ in BConnectedAccountAcceptanceClient() })
    }
}

extension BConnectedPublicationConfiguration {
    /// Separate HTTPS origin/trust, never inferred from the messaging socket or enrollment origin.
    public init(info: [String: Any]) throws {
        guard let string = info["BConnectedAccountPublicationOrigin"] as? String, let origin = URL(string: string),
              info["BConnectedAccountPublicationTrust"] as? String == "system",
              info["BConnectedAccountPublicationCertificateDERBase64"] == nil else { throw BConnectedEnrollmentError.unavailable }
        let authority = try BConnectedOwnedCryptographicConfiguration(info: info)
        let bytes = try BConnectedEnrollmentWire.encode(["groups": authority.groupServerPublicParams.base64EncodedString(),
                                                       "senders": authority.senderCertificateTrustRoots])
        try self.init(origin: origin, authorityCommitment: Data(SHA256.hash(data: bytes)))
    }
}
