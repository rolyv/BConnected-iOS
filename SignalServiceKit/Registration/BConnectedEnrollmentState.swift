// Copyright 2026 BConnected contributors. SPDX-License-Identifier: AGPL-3.0-only

public import Foundation
import LibSignalClient
import Security
import CryptoKit

/// Inputs are frozen before the first community intent. APNs may be absent for manual-fetch tests.
public struct BConnectedEnrollmentPreparation {
    let phone: String
    let unidentifiedAccessKey: Data
    let apnsToken: String?
    let discoverableByPhoneNumber: Bool
    let signalAgent: String
    let userAgent: String

    public init(phone: String, unidentifiedAccessKey: Data, apnsToken: String?, discoverableByPhoneNumber: Bool,
                signalAgent: String, userAgent: String) {
        self.phone = phone; self.unidentifiedAccessKey = unidentifiedAccessKey; self.apnsToken = apnsToken
        self.discoverableByPhoneNumber = discoverableByPhoneNumber
        self.signalAgent = signalAgent; self.userAgent = userAgent
    }
}

/// Safe public projection to create a community intent. It is neither an approval nor phone proof.
public struct BConnectedEnrollmentIntentMaterial: Equatable {
    public let registrationAttemptId: String
    public let keyCommitment: String
}

/// Persisted progress is informational; only the native lifecycle adapter may finish registration.
public struct BConnectedEnrollmentProgress {
    public let intent: BConnectedEnrollmentIntentMaterial
    public let hasApprovedIntentBinding: Bool
    public let hasOperation: Bool
    public let smsOutcomeNeedsExplicitDecision: Bool
    public let lastObservation: BConnectedEnrollmentObservation?
    /// Installed locally, but deliberately not registered or messaging-ready.
    public let nativeAccountInstalled: Bool
    public let localAccountPrepared: Bool
    public let accountEntropyPrepared: Bool
    public let accountPublicationComplete: Bool
    public let accountPublicationNeedsExplicitRetry: Bool
    public let preKeyPublicationComplete: Bool
    public let preKeyPublicationUncertain: Bool
}

/// All secret material stays in the encrypted app DB. Never log or reflect this record.
struct BConnectedEnrollmentRecord: Codable, CustomStringConvertible, CustomDebugStringConvertible {
    struct Identity: Codable {
        let pair: Data
        let signedPreKey: Data
        let lastResortPreKey: Data

        static func generate() throws -> Self {
            let pair = IdentityKeyPair.generate()
            let ec = PrivateKey.generate()
            let kem = KEMKeyPair.generate()
            let time = UInt64(Date().timeIntervalSince1970 * 1000)
            let signed = try SignedPreKeyRecord(id: UInt32.random(in: 0...UInt32(Int32.max)), timestamp: time,
                                               privateKey: ec, signature: pair.privateKey.generateSignature(message: ec.publicKey.serialize()))
            let lastResort = try KyberPreKeyRecord(id: UInt32.random(in: 0...UInt32(Int32.max)), timestamp: time,
                                                keyPair: kem, signature: pair.privateKey.generateSignature(message: kem.publicKey.serialize()))
            return Self(pair: pair.serialize(), signedPreKey: signed.serialize(), lastResortPreKey: lastResort.serialize())
        }

        func publicFields(prefix: String) throws -> [String: Any] {
            let pair = try IdentityKeyPair(bytes: pair)
            let ec = try SignedPreKeyRecord(bytes: signedPreKey)
            guard pair.privateKey.publicKey.serialize() == pair.publicKey.serialize(),
                  try ec.privateKey().publicKey.serialize() == ec.publicKey().serialize() else { throw BConnectedEnrollmentError.persistenceUnavailable }
            let kem = try KyberPreKeyRecord(bytes: lastResortPreKey)
            return [prefix + "IdentityKey": pair.identityKey.serialize().base64EncodedString(),
                    prefix + "SignedPreKey": ["keyId": ec.id, "publicKey": try ec.publicKey().serialize().base64EncodedString(), "signature": ec.signature.base64EncodedString()],
                    prefix + "PqLastResortPreKey": ["keyId": kem.id, "publicKey": try kem.publicKey().serialize().base64EncodedString(), "signature": kem.signature.base64EncodedString()]]
        }
    }

    let version: Int
    let phone: String
    let password: String
    let attempt: String
    let originalSignalAgent: String
    let originalUserAgent: String
    let aci: Identity
    let pni: Identity
    let registrationRequest: Data
    let keyCommitment: String
    var binding: Binding?
    var operationId: String?
    /// Written BEFORE any SMS dispatch. An unknown outcome requires an explicit user resend decision.
    var sendNeedsExplicitDecision = false
    var observation: BConnectedEnrollmentObservation?
    var installedAccount: BConnectedEnrollmentObservation.Account?
    var localSetupReceipt: LocalSetupReceipt?
    var accountEntropyReceipt: AccountEntropyReceipt?
    var publication: Publication?
    var preKeyPublication: PreKeyPublication?

    struct Publication: Codable, Equatable {
        enum State: String, Codable { case prepared, dispatched, acknowledged }
        let version: Int
        let configurationHash: Data
        let entropyReceipt: AccountEntropyReceipt
        let profileStateHash: Data
        let accountAttributes: Data
        let encryptedProfile: Data
        let payloadHash: Data
        var attributesState: State = .prepared
        var profileState: State = .prepared
        var complete: Bool { attributesState == .acknowledged && profileState == .acknowledged }
        var uncertain: Bool { attributesState == .dispatched || profileState == .dispatched }
        func state(for step: BConnectedPublicationStep) -> State { step == .attributes ? attributesState : profileState }
        static func hash(attributes: Data, profile: Data) -> Data {
            Data(SHA256.hash(data: Data(SHA256.hash(data: attributes)) + Data(SHA256.hash(data: profile))))
        }
    }

    struct PreKeyPublication: Codable, Equatable {
        struct Batch: Codable, Equatable {
            let ec: [Data]
            let pq: [Data]
            let request: Data
            var state: Publication.State = .prepared

            static func request(ec: [Data], pq: [Data], identity: Identity) throws -> Data {
                guard ec.count == 100, pq.count == 100 else { throw BConnectedEnrollmentError.persistenceUnavailable }
                let pair = try IdentityKeyPair(bytes: identity.pair)
                let lastResort = try LibSignalClient.KyberPreKeyRecord(bytes: identity.lastResortPreKey)
                let ecKeys = try ec.map { try LibSignalClient.PreKeyRecord(bytes: $0) }
                let pqKeys = try pq.map { try LibSignalClient.KyberPreKeyRecord(bytes: $0) }
                guard Set(ecKeys.map(\.id)).count == 100, Set(pqKeys.map(\.id)).count == 100,
                      !pqKeys.contains(where: { $0.id == lastResort.id }) else { throw BConnectedEnrollmentError.persistenceUnavailable }
                let ecFields: [[String: Any]] = try zip(ecKeys, ec).map { key, bytes in
                    guard key.id > 0, key.id < 0x1000000, key.serialize() == bytes,
                          try key.privateKey().publicKey.serialize() == key.publicKey().serialize() else { throw BConnectedEnrollmentError.persistenceUnavailable }
                    return ["keyId": key.id, "publicKey": try key.publicKey().serialize().base64EncodedString()]
                }
                let pqFields: [[String: Any]] = try zip(pqKeys, pq).map { key, bytes in
                    guard key.id > 0, key.id < 0x1000000, key.serialize() == bytes,
                          try pair.publicKey.verifySignature(message: key.publicKey().serialize(), signature: key.signature) else { throw BConnectedEnrollmentError.persistenceUnavailable }
                    return ["keyId": key.id, "publicKey": try key.publicKey().serialize().base64EncodedString(), "signature": key.signature.base64EncodedString()]
                }
                // Native PQ public keys make a 100-key batch larger than enrollment's 64 KiB
                // envelope. Keep that limit unchanged and bound this exact public-only schema.
                let bytes = try JSONSerialization.data(withJSONObject: ["preKeys": ecFields, "pqPreKeys": pqFields], options: [.sortedKeys, .withoutEscapingSlashes])
                guard bytes.count <= 524_288 else { throw BConnectedEnrollmentError.persistenceUnavailable }
                return bytes
            }
        }
        let version: Int
        let contextHash: Data
        var aci: Batch
        var pni: Batch
        var complete: Bool { aci.state == .acknowledged && pni.state == .acknowledged }
        var uncertain: Bool { aci.state == .dispatched || pni.state == .dispatched }
        func batch(_ identity: BConnectedPreKeyIdentity) -> Batch { identity == .aci ? aci : pni }
    }

    /// Includes the original credential and binding, never a renewed request's authority or identity.
    func preKeyContextHash() throws -> Data {
        guard let publication, publication.complete, let binding, let operationId, let installedAccount else {
            throw BConnectedEnrollmentError.immutableConflict
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return Data(SHA256.hash(data: try BConnectedEnrollmentWire.encode([
            "domain": "BConnected pending one-time keys v1", "attempt": attempt, "commitment": keyCommitment,
            "member": binding.memberId, "challenge": binding.challenge, "operation": operationId,
            "account": try encoder.encode(installedAccount).base64EncodedString(), "password": password,
            "signalAgent": originalSignalAgent, "userAgent": originalUserAgent,
            "publication": try encoder.encode(publication).base64EncodedString(),
        ])))
    }

    struct AccountEntropyReceipt: Codable, Equatable {
        let version: Int
        let localSetup: LocalSetupReceipt
        let entropyHash: Data
    }

    struct LocalSetupReceipt: Codable, Equatable {
        let version: Int
        let attempt: String
        let keyCommitment: String
        let account: BConnectedEnrollmentObservation.Account
        let profileUniqueId: String
        let profileAccessKeyHash: Data
        let recipientId: Int64
        let recipientUniqueId: String
    }

    func profileAccessKeyHash() throws -> Data {
        let request = try BConnectedEnrollmentWire.object(registrationRequest)
        guard let attributes = request["accountAttributes"] as? [String: Any] else { throw BConnectedEnrollmentError.persistenceUnavailable }
        return Data(SHA256.hash(data: try BConnectedEnrollmentWire.base64(BConnectedEnrollmentWire.text(attributes["unidentifiedAccessKey"]))))
    }

    struct Binding: Codable, Equatable { let memberId: String; let challenge: String }
    var description: String { "BConnectedEnrollmentRecord(redacted)" }
    var debugDescription: String { description }

    static func generate(_ input: BConnectedEnrollmentPreparation) throws -> Self {
        try BConnectedEnrollmentWire.phone(input.phone)
        _ = try BConnectedEnrollmentWire.metadata(input.signalAgent, limit: 256)
        _ = try BConnectedEnrollmentWire.metadata(input.userAgent, limit: 512)
        guard input.unidentifiedAccessKey.count == 16 else { throw BConnectedEnrollmentError.invalidInput }
        if let token = input.apnsToken { _ = try BConnectedEnrollmentWire.metadata(token, limit: 4096) }
        let aci = try Identity.generate(), pni = try Identity.generate()
        var request: [String: Any] = ["skipDeviceTransfer": true,
            "accountAttributes": ["fetchesMessages": input.apnsToken == nil,
                "registrationId": Int.random(in: 1...16383), "pniRegistrationId": Int.random(in: 1...16383),
                "unidentifiedAccessKey": input.unidentifiedAccessKey.base64EncodedString(),
                "unrestrictedUnidentifiedAccess": false, "discoverableByPhoneNumber": input.discoverableByPhoneNumber,
                "capabilities": ["spqr": true]]]
        if let token = input.apnsToken { request["apnToken"] = ["apnRegistrationId": token] }
        request.merge(try aci.publicFields(prefix: "aci")) { _, new in new }
        request.merge(try pni.publicFields(prefix: "pni")) { _, new in new }
        return Self(version: 1, phone: input.phone, password: try randomBytes().base64EncodedString(),
                    attempt: BConnectedEnrollmentWire.base64url(try randomBytes()),
                    originalSignalAgent: input.signalAgent, originalUserAgent: input.userAgent,
                    aci: aci, pni: pni, registrationRequest: try BConnectedEnrollmentWire.encode(request),
                    keyCommitment: try BConnectedEnrollmentWire.registration(request))
    }

    /// Corrupt/version-mismatched state is terminal; never replace it with freshly generated keys.
    func validate() throws {
        guard version == 1, try BConnectedEnrollmentWire.base64(password).count == 32 else { throw BConnectedEnrollmentError.persistenceUnavailable }
        try BConnectedEnrollmentWire.phone(phone)
        _ = try BConnectedEnrollmentWire.nonce(attempt)
        _ = try BConnectedEnrollmentWire.metadata(originalSignalAgent, limit: 256)
        _ = try BConnectedEnrollmentWire.metadata(originalUserAgent, limit: 512)
        let request = try BConnectedEnrollmentWire.object(registrationRequest)
        guard try BConnectedEnrollmentWire.registration(request) == keyCommitment else { throw BConnectedEnrollmentError.persistenceUnavailable }
        for (key, value) in try aci.publicFields(prefix: "aci").merging(pni.publicFields(prefix: "pni"), uniquingKeysWith: { _, new in new }) {
            guard let actual = request[key], NSDictionary(dictionary: [key: value]).isEqual(to: [key: actual]) else { throw BConnectedEnrollmentError.persistenceUnavailable }
        }
        if let binding { _ = try BConnectedEnrollmentWire.uuid(binding.memberId); _ = try BConnectedEnrollmentWire.nonce(binding.challenge) }
        if let operationId { _ = try BConnectedEnrollmentWire.uuid(operationId); guard binding != nil else { throw BConnectedEnrollmentError.persistenceUnavailable } }
        if let observation { guard observation.operationId == operationId else { throw BConnectedEnrollmentError.persistenceUnavailable } }
        if let installedAccount {
            guard operationId != nil, installedAccount.number == phone, installedAccount.deviceId == 1 else { throw BConnectedEnrollmentError.persistenceUnavailable }
            _ = try BConnectedEnrollmentWire.uuid(installedAccount.aci)
            _ = try BConnectedEnrollmentWire.uuid(installedAccount.pni)
        }
        if let receipt = localSetupReceipt {
            guard receipt.version == 1, receipt.attempt == attempt, receipt.keyCommitment == keyCommitment,
                  receipt.account == installedAccount, receipt.recipientId > 0,
                  !receipt.recipientUniqueId.isEmpty, !receipt.profileUniqueId.isEmpty,
                  try receipt.profileAccessKeyHash == profileAccessKeyHash() else { throw BConnectedEnrollmentError.persistenceUnavailable }
        }
        if let receipt = accountEntropyReceipt {
            guard receipt.version == 1, receipt.localSetup == localSetupReceipt, receipt.entropyHash.count == 32 else {
                throw BConnectedEnrollmentError.persistenceUnavailable
            }
        }
        if let publication {
            guard publication.version == 1, publication.configurationHash.count == 32,
                  publication.entropyReceipt == accountEntropyReceipt, publication.profileStateHash.count == 32,
                  publication.payloadHash == Publication.hash(attributes: publication.accountAttributes, profile: publication.encryptedProfile),
                  publication.profileState == .prepared || publication.attributesState == .acknowledged,
                  let attributes = request["accountAttributes"] as? [String: Any],
                  publication.accountAttributes == (try BConnectedEnrollmentWire.encode(attributes)) else {
                throw BConnectedEnrollmentError.persistenceUnavailable
            }
            let profile = try BConnectedEnrollmentWire.object(publication.encryptedProfile)
            guard Set(profile.keys).isSubset(of: ["name", "about", "aboutEmoji", "avatar", "sameAvatar", "badgeIds", "commitment", "phoneNumberSharing", "version"]),
                  profile["avatar"] as? Bool == true, profile["sameAvatar"] as? Bool == true,
                  (profile["badgeIds"] as? [String])?.isEmpty == true,
                  let profileVersion = profile["version"] as? String, profileVersion.count == 64,
                  profileVersion.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw BConnectedEnrollmentError.persistenceUnavailable
            }
            let commitment = try BConnectedEnrollmentWire.base64(profile["commitment"])
            guard try ProfileKeyCommitment(contents: commitment).serialize() == commitment,
                  try BConnectedEnrollmentWire.base64(profile["phoneNumberSharing"]).count == 29 else {
                throw BConnectedEnrollmentError.persistenceUnavailable
            }
            for (field, sizes) in [("name", [81, 285]), ("about", [156, 282, 540]), ("aboutEmoji", [60])] {
                if let value = profile[field], !sizes.contains(try BConnectedEnrollmentWire.base64(value).count) {
                    throw BConnectedEnrollmentError.persistenceUnavailable
                }
            }
        }
        try validatePreKeyPublication()
    }

    func validatePreKeyPublication() throws {
        guard let keys = preKeyPublication else { return }
        guard keys.version == 1, keys.contextHash == (try preKeyContextHash()),
              keys.pni.state == .prepared || keys.aci.state == .acknowledged,
              keys.aci.request == (try PreKeyPublication.Batch.request(ec: keys.aci.ec, pq: keys.aci.pq, identity: aci)),
              keys.pni.request == (try PreKeyPublication.Batch.request(ec: keys.pni.ec, pq: keys.pni.pq, identity: pni)) else {
            throw BConnectedEnrollmentError.persistenceUnavailable
        }
    }

    func body(for operation: BConnectedEnrollmentOperation, code: String?) throws -> Data {
        guard let binding else { throw BConnectedEnrollmentError.approvalBindingRequired }
        var root: [String: Any] = ["memberId": binding.memberId, "registrationAttemptId": attempt,
            "bindingChallenge": binding.challenge, "registrationRequest": try BConnectedEnrollmentWire.object(registrationRequest),
            "originalSignalAgent": originalSignalAgent, "originalUserAgent": originalUserAgent]
        if let code { root["code"] = code }
        let data = try BConnectedEnrollmentWire.encode(root)
        try BConnectedEnrollmentWire.request(data, operation: operation)
        return data
    }

    private static func randomBytes() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw BConnectedEnrollmentError.unavailable }
        return Data(bytes)
    }
}

/// The transaction must commit before returning. Implementations must not swallow persistence errors.
protocol BConnectedEnrollmentPersistence {
    func transaction<T>(_ update: (inout BConnectedEnrollmentRecord?) throws -> T) throws -> T
    var supportsNativeInstallation: Bool { get }
    func prepareLocalAccount() throws
    func prepareAccountEntropy() throws
    func preparePreKeys(configuration: BConnectedPublicationConfiguration) throws -> BConnectedEnrollmentRecord
    func transitionPreKeys(expected: BConnectedEnrollmentRecord, identity: BConnectedPreKeyIdentity, acknowledge: Bool) throws -> BConnectedEnrollmentRecord
    func preparePublication(configuration: BConnectedPublicationConfiguration) throws -> BConnectedEnrollmentRecord
    func transitionPublication(expected: BConnectedEnrollmentRecord, step: BConnectedPublicationStep, acknowledge: Bool) throws -> BConnectedEnrollmentRecord
    /// Must atomically install the exact saved native keys/account AND its installedAccount receipt.
    func installNativeAccount(expected: BConnectedEnrollmentRecord, account: BConnectedEnrollmentObservation.Account) throws
}

extension BConnectedEnrollmentPersistence {
    var supportsNativeInstallation: Bool { false }
    func preparePreKeys(configuration: BConnectedPublicationConfiguration) throws -> BConnectedEnrollmentRecord { throw BConnectedEnrollmentError.unavailable }
    func transitionPreKeys(expected: BConnectedEnrollmentRecord, identity: BConnectedPreKeyIdentity, acknowledge: Bool) throws -> BConnectedEnrollmentRecord { throw BConnectedEnrollmentError.unavailable }
    func prepareLocalAccount() throws { throw BConnectedEnrollmentError.unavailable }
    func prepareAccountEntropy() throws { throw BConnectedEnrollmentError.unavailable }
    func preparePublication(configuration: BConnectedPublicationConfiguration) throws -> BConnectedEnrollmentRecord { throw BConnectedEnrollmentError.unavailable }
    func transitionPublication(expected: BConnectedEnrollmentRecord, step: BConnectedPublicationStep, acknowledge: Bool) throws -> BConnectedEnrollmentRecord { throw BConnectedEnrollmentError.unavailable }
    func installNativeAccount(expected: BConnectedEnrollmentRecord, account: BConnectedEnrollmentObservation.Account) throws {
        throw BConnectedEnrollmentError.unavailable
    }
}

/// Serial orchestration with durable immutable inputs; separate from native-account lifecycle completion.
@MainActor
public final class BConnectedEnrollmentCoordinator {
    private let persistence: any BConnectedEnrollmentPersistence
    private let client: any BConnectedEnrollmentSending
    private let publicationConfiguration: BConnectedPublicationConfiguration?
    private let publisher: (any BConnectedPublicationSending)?
    private let preKeyPublisher: (any BConnectedPreKeySending)?
    private var inFlight = false
    public var supportsPreKeyPublication: Bool { publicationConfiguration != nil && preKeyPublisher != nil && persistence.supportsNativeInstallation }
    public var supportsAccountPublication: Bool { publicationConfiguration != nil && publisher != nil && persistence.supportsNativeInstallation }

    init(persistence: any BConnectedEnrollmentPersistence, client: any BConnectedEnrollmentSending,
         publicationConfiguration: BConnectedPublicationConfiguration? = nil, publisher: (any BConnectedPublicationSending)? = nil, preKeyPublisher: (any BConnectedPreKeySending)? = nil) {
        self.persistence = persistence; self.client = client
        self.publicationConfiguration = publicationConfiguration; self.publisher = publisher; self.preKeyPublisher = preKeyPublisher
    }

    /// First call commits secrets and public request; subsequent calls reuse them, including original metadata.
    public func prepare(_ input: BConnectedEnrollmentPreparation) throws -> BConnectedEnrollmentIntentMaterial {
        try persistence.transaction { record in
            if let existing = record {
                try existing.validate()
                guard existing.phone == input.phone else { throw BConnectedEnrollmentError.immutableConflict }
            } else { record = try .generate(input) }
            return .init(registrationAttemptId: record!.attempt, keyCommitment: record!.keyCommitment)
        }
    }

    public func progress() throws -> BConnectedEnrollmentProgress? {
        try persistence.transaction { record in
            guard let record else { return nil }
            try record.validate()
            return .init(intent: .init(registrationAttemptId: record.attempt, keyCommitment: record.keyCommitment),
                         hasApprovedIntentBinding: record.binding != nil, hasOperation: record.operationId != nil,
                         smsOutcomeNeedsExplicitDecision: record.sendNeedsExplicitDecision, lastObservation: record.observation,
                         nativeAccountInstalled: record.installedAccount != nil, localAccountPrepared: record.localSetupReceipt != nil,
                         accountEntropyPrepared: record.accountEntropyReceipt != nil,
                         accountPublicationComplete: record.publication?.complete == true,
                         accountPublicationNeedsExplicitRetry: record.publication?.uncertain == true,
                         preKeyPublicationComplete: record.preKeyPublication?.complete == true,
                         preKeyPublicationUncertain: record.preKeyPublication?.uncertain == true)
        }
    }

    /// Caller supplies the approved community intent. This does not set phone/account authorization.
    public func bindApprovedIntent(memberId: String, challenge: String) throws {
        let binding = BConnectedEnrollmentRecord.Binding(memberId: try BConnectedEnrollmentWire.uuid(memberId), challenge: try BConnectedEnrollmentWire.nonce(challenge))
        try persistence.transaction { record in
            guard var existing = record else { throw BConnectedEnrollmentError.missingAttempt }
            try existing.validate()
            guard existing.binding == nil || existing.binding == binding else { throw BConnectedEnrollmentError.immutableConflict }
            existing.binding = binding; record = existing
        }
    }

    public func perform(_ operation: BConnectedEnrollmentOperation, code: String? = nil,
                        explicitlyResendAfterUncertainOutcome: Bool = false) async throws -> BConnectedEnrollmentObservation {
        guard !inFlight else { throw BConnectedEnrollmentError.busy }
        inFlight = true; defer { inFlight = false }
        return try await performUnlocked(operation, code: code, explicitlyResendAfterUncertainOutcome: explicitlyResendAfterUncertainOutcome)
    }

    /// Local-only preparation; never authorizes messaging or refreshes remote enrollment state.
    public func prepareLocalAccount() throws {
        guard !inFlight else { throw BConnectedEnrollmentError.busy }
        guard persistence.supportsNativeInstallation else { throw BConnectedEnrollmentError.unavailable }
        inFlight = true; defer { inFlight = false }
        try persistence.prepareLocalAccount()
    }

    /// First-install local key setup. This never releases pending-services or publishes anything.
    public func prepareAccountEntropy() throws {
        guard !inFlight else { throw BConnectedEnrollmentError.busy }
        guard persistence.supportsNativeInstallation else { throw BConnectedEnrollmentError.unavailable }
        inFlight = true; defer { inFlight = false }
        try persistence.prepareAccountEntropy()
    }

    /// Explicit, bounded publication while the ordinary account reader still withholds credentials.
    /// A persisted dispatch marker survives every failure. Replays require an explicit decision.
    public func publishAccount(explicitlyRetryUncertainOutcome: Bool = false) async throws {
        guard !inFlight else { throw BConnectedEnrollmentError.busy }
        guard let configuration = publicationConfiguration, let publisher,
              persistence.supportsNativeInstallation else { throw BConnectedEnrollmentError.unavailable }
        inFlight = true; defer { inFlight = false }
        let status = try await performUnlocked(.status, code: nil, explicitlyResendAfterUncertainOutcome: false)
        guard status.state == .active, status.registrationAuthorized == true else { throw BConnectedEnrollmentError.immutableConflict }
        var record = try persistence.preparePublication(configuration: configuration)
        guard status.account == record.installedAccount else { throw BConnectedEnrollmentError.immutableConflict }
        for step in [BConnectedPublicationStep.attributes, .profile] {
            guard let publication = record.publication else { throw BConnectedEnrollmentError.persistenceUnavailable }
            if publication.state(for: step) == .acknowledged { continue }
            if publication.state(for: step) == .dispatched && !explicitlyRetryUncertainOutcome {
                throw BConnectedEnrollmentError.explicitPublicationRetryRequired
            }
            record = try persistence.transitionPublication(expected: record, step: step, acknowledge: false)
            try Task.checkCancellation()
            try await publisher.send(step, record: record, configuration: configuration)
            record = try persistence.transitionPublication(expected: record, step: step, acknowledge: true)
        }
        // Publication acknowledgement is not a services-ready capability or registration event.
    }

    /// The replace-pool server API has no idempotency tombstone. Any uncertain dispatch is
    /// terminal here: even an explicit retry could restore already-consumed one-time key IDs.
    public func publishPreKeys() async throws {
        guard !inFlight else { throw BConnectedEnrollmentError.busy }
        guard let configuration = publicationConfiguration, let preKeyPublisher,
              persistence.supportsNativeInstallation else { throw BConnectedEnrollmentError.unavailable }
        inFlight = true; defer { inFlight = false }
        let status = try await performUnlocked(.status, code: nil, explicitlyResendAfterUncertainOutcome: false)
        guard status.state == .active, status.registrationAuthorized == true else { throw BConnectedEnrollmentError.immutableConflict }
        var record = try persistence.preparePreKeys(configuration: configuration)
        guard status.account == record.installedAccount else { throw BConnectedEnrollmentError.immutableConflict }
        for identity in [BConnectedPreKeyIdentity.aci, .pni] {
            guard let keys = record.preKeyPublication else { throw BConnectedEnrollmentError.persistenceUnavailable }
            if keys.batch(identity).state == .acknowledged { continue }
            guard keys.batch(identity).state == .prepared else { throw BConnectedEnrollmentError.uncertainPreKeyPublication }
            record = try persistence.transitionPreKeys(expected: record, identity: identity, acknowledge: false)
            try Task.checkCancellation()
            try await preKeyPublisher.send(identity, record: record, configuration: configuration)
            record = try persistence.transitionPreKeys(expected: record, identity: identity, acknowledge: true)
        }
        // These acknowledgements never publish registration or release pending-services.
    }

    /// A persisted active observation is not authorization to install. Always fetch fresh status.
    /// This does not publish registration notifications, open chat, or return the registration .done step.
    public func installNativeAccount() async throws {
        guard !inFlight else { throw BConnectedEnrollmentError.busy }
        guard persistence.supportsNativeInstallation else { throw BConnectedEnrollmentError.unavailable }
        inFlight = true; defer { inFlight = false }
        let fresh = try await performUnlocked(.status)
        guard fresh.state == .active, fresh.registrationAuthorized, let account = fresh.account else {
            throw BConnectedEnrollmentError.unavailable
        }
        let snapshot = try persistence.transaction { record in
            guard let record, record.observation == fresh, record.operationId == fresh.operationId,
                  account.number == record.phone, account.deviceId == 1 else { throw BConnectedEnrollmentError.immutableConflict }
            try record.validate()
            guard record.installedAccount == nil || record.installedAccount == account else { throw BConnectedEnrollmentError.immutableConflict }
            return record
        }
        try persistence.installNativeAccount(expected: snapshot, account: account)
    }

    private func performUnlocked(_ operation: BConnectedEnrollmentOperation, code: String? = nil,
                                 explicitlyResendAfterUncertainOutcome: Bool = false) async throws -> BConnectedEnrollmentObservation {
        // Input validation and a durable SMS dispatch marker precede the first network effect.
        let snapshot = try persistence.transaction { record in
            guard var existing = record else { throw BConnectedEnrollmentError.missingAttempt }
            try existing.validate()
            if operation != .begin && existing.operationId == nil { throw BConnectedEnrollmentError.operationRequired }
            if operation == .begin && existing.operationId != nil { throw BConnectedEnrollmentError.immutableConflict }
            _ = try existing.body(for: operation, code: code)
            if operation == .sendCode {
                guard !existing.sendNeedsExplicitDecision || explicitlyResendAfterUncertainOutcome else { throw BConnectedEnrollmentError.explicitSendRequired }
                existing.sendNeedsExplicitDecision = true
            }
            record = existing
            return existing
        }
        let result: BConnectedEnrollmentObservation
        do { result = try await client.send(operation, record: snapshot, code: code) }
        catch let error as BConnectedEnrollmentError { throw error }
        catch { throw BConnectedEnrollmentError.unavailable }
        return try persistence.transaction { record in
            guard var existing = record, existing.attempt == snapshot.attempt,
                  existing.operationId == snapshot.operationId else { throw BConnectedEnrollmentError.immutableConflict }
            // Only strict wire observations are stored; account initialization is a later explicit operation.
            existing.operationId = result.operationId; existing.observation = result
            if operation == .sendCode { existing.sendNeedsExplicitDecision = false }
            record = existing
            return result
        }
    }
}
