// Copyright 2026 BConnected contributors. SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import LibSignalClient

/// Installs a primary device locally without exposing its credentials to networking or announcing
/// registration. Releasing the pending-services barrier requires a separate, complete service graph.
public struct BConnectedNativeAccountInstaller {
    private let accountManager: TSAccountManagerImpl
    private let identityManager: OWSIdentityManagerImpl
    private let protocolStores: SignalProtocolStoreManager

    public init?(accountManager: TSAccountManager, identityManager: OWSIdentityManager,
                 protocolStores: SignalProtocolStoreManager) {
        guard let accountManager = accountManager as? TSAccountManagerImpl,
              let identityManager = identityManager as? OWSIdentityManagerImpl else { return nil }
        self.accountManager = accountManager
        self.identityManager = identityManager
        self.protocolStores = protocolStores
    }

    func preparePreKeys(record: BConnectedEnrollmentRecord, tx: DBWriteTransaction) throws -> BConnectedEnrollmentRecord {
        try BConnectedPreKeySetup.prepare(record: record, preKeyStore: protocolStores.preKeyStore, tx: tx)
    }

    func transitionPreKeys(record: BConnectedEnrollmentRecord, expected: BConnectedEnrollmentRecord,
                           identity: BConnectedPreKeyIdentity, acknowledge: Bool, tx: DBWriteTransaction) throws -> BConnectedEnrollmentRecord {
        try BConnectedPreKeySetup.transition(record: record, expected: expected, identity: identity,
            acknowledge: acknowledge, preKeyStore: protocolStores.preKeyStore, tx: tx)
    }

    /// All parsing and validation precede the returned nonthrowing mutation closure. Callers must
    /// serialize the final enrollment receipt first and run both writes in the same SQLCipher tx.
    func prepare(record: BConnectedEnrollmentRecord, account: BConnectedEnrollmentObservation.Account,
                 tx: DBWriteTransaction) throws -> () -> Void {
        try record.validate()
        let material = try BConnectedNativeAccountMaterial(record: record, account: account)
        let repeated = record.installedAccount != nil
        guard !repeated || record.installedAccount == account else { throw BConnectedEnrollmentError.immutableConflict }
        try accountManager.validateBConnectedInstallation(material, repeated: repeated, tx: tx)
        guard let profileKey = OWSUserProfile.getUserProfileForLocalUser(tx: tx)?.profileKey,
              SMKUDAccessKey(profileKey: profileKey).keyData == material.unidentifiedAccessKey else {
            throw BConnectedEnrollmentError.immutableConflict
        }
        let identities: [(OWSIdentity, BConnectedEnrollmentRecord.Identity)] = [(.aci, record.aci), (.pni, record.pni)]
        var writes: [() -> Void] = []
        for (identity, saved) in identities {
            let pair = try IdentityKeyPair(bytes: saved.pair).asECKeyPair
            let signed = try LibSignalClient.SignedPreKeyRecord(bytes: saved.signedPreKey)
            let kyber = try LibSignalClient.KyberPreKeyRecord(bytes: saved.lastResortPreKey)
            let existingPair = identityManager.identityKeyPair(for: identity, tx: tx)
            let store = protocolStores.signalProtocolStore(for: identity)
            let records = protocolStores.preKeyStore.forIdentity(identity)
            let existingSigned = records.fetchPreKey(in: .signed, for: signed.id, tx: tx)
            let existingKyber = records.fetchPreKey(in: .kyber, for: kyber.id, tx: tx)
            if repeated {
                guard existingPair?.identityKeyPair.serialize() == saved.pair,
                      existingSigned?.serializedRecord == saved.signedPreKey, existingSigned?.isOneTime == false,
                      existingKyber?.serializedRecord == saved.lastResortPreKey, existingKyber?.isOneTime == false else {
                    throw BConnectedEnrollmentError.immutableConflict
                }
            } else {
                guard existingPair == nil, !records.bconnectedHasAnyKeys(tx: tx) else { throw BConnectedEnrollmentError.immutableConflict }
                writes.append(try identityManager.prepareBConnectedIdentityKeyPair(pair, for: identity, tx: tx))
                writes.append(try store.signedPreKeyStore.prepareBConnectedInitialKey(signed, tx: tx))
                writes.append(try store.kyberPreKeyStore.prepareBConnectedInitialKey(kyber, tx: tx))
            }
        }
        // Exact retries are read-only: no rotation, timestamp rewrite, credential replacement,
        // registration notification, recipient merge, storage-service action, or network request.
        return {
            guard !repeated else { return }
            for write in writes { write() }
            accountManager.stageBConnectedInstallation(material, tx: tx)
        }
    }
}

struct BConnectedNativeAccountMaterial {
    let account: BConnectedEnrollmentObservation.Account
    let password: String
    let aci: Aci
    let pni: Pni
    let registrationId: UInt32
    let pniRegistrationId: UInt32
    let manualFetch: Bool
    let discoverable: Bool
    let unidentifiedAccessKey: Data

    init(record: BConnectedEnrollmentRecord, account: BConnectedEnrollmentObservation.Account) throws {
        guard account.number == record.phone, account.deviceId == 1,
              let aciUUID = UUID(uuidString: try BConnectedEnrollmentWire.uuid(account.aci)),
              let pniUUID = UUID(uuidString: try BConnectedEnrollmentWire.uuid(account.pni)) else { throw BConnectedEnrollmentError.invalidResponse }
        let request = try BConnectedEnrollmentWire.object(record.registrationRequest)
        guard let attrs = request["accountAttributes"] as? [String: Any],
              let registrationId = attrs["registrationId"] as? UInt32,
              let pniRegistrationId = attrs["pniRegistrationId"] as? UInt32,
              let manualFetch = attrs["fetchesMessages"] as? Bool,
              let discoverable = attrs["discoverableByPhoneNumber"] as? Bool,
              let accessKey = attrs["unidentifiedAccessKey"] as? String,
              let accessKeyData = Data(base64Encoded: accessKey) else { throw BConnectedEnrollmentError.persistenceUnavailable }
        self.account = account; self.password = record.password
        self.aci = Aci(fromUUID: aciUUID); self.pni = Pni(fromUUID: pniUUID)
        self.registrationId = registrationId; self.pniRegistrationId = pniRegistrationId
        self.manualFetch = manualFetch; self.discoverable = discoverable; self.unidentifiedAccessKey = accessKeyData
    }
}
