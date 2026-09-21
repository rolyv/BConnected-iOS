// Copyright 2026 BConnected contributors. SPDX-License-Identifier: AGPL-3.0-only

public import Foundation
import LibSignalClient
import Security

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
}

/// Serial orchestration with durable immutable inputs; separate from native-account lifecycle completion.
@MainActor
public final class BConnectedEnrollmentCoordinator {
    private let persistence: any BConnectedEnrollmentPersistence
    private let client: any BConnectedEnrollmentSending
    private var inFlight = false

    init(persistence: any BConnectedEnrollmentPersistence, client: any BConnectedEnrollmentSending) {
        self.persistence = persistence; self.client = client
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
                         smsOutcomeNeedsExplicitDecision: record.sendNeedsExplicitDecision, lastObservation: record.observation)
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
