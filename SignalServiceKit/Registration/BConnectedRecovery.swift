// Copyright 2026 BConnected contributors. SPDX-License-Identifier: AGPL-3.0-only
public import Foundation
import GRDB

public struct BConnectedRecoveryObservation: Codable, Equatable {
    public enum State: String, Codable { case verification, awaitingAuthorization = "awaiting_authorization", authorized, recovering, active, suspended }
    public let recoveryId: String
    public let state: State
    public let phoneVerified: Bool
    public let nextSmsSeconds: Int?
    public let nextCheckSeconds: Int?
    public let expiresInSeconds: Int
    public let registrationAuthorized: Bool
    public let memberId: String?
    public let account: BConnectedEnrollmentObservation.Account?
    public let fullName: String?
    public let graduationYear: Int?

    var metadata: Metadata? {
        guard let memberId, let account, let fullName, let graduationYear else { return nil }
        return .init(memberId: memberId, account: account, fullName: fullName, graduationYear: graduationYear)
    }
    struct Metadata: Codable, Equatable {
        let memberId: String
        let account: BConnectedEnrollmentObservation.Account
        let fullName: String
        let graduationYear: Int
    }
    func validate(phone: String) throws {
        _ = try BConnectedEnrollmentWire.uuid(recoveryId)
        guard registrationAuthorized == (state == .active), (0...2_678_400).contains(expiresInSeconds),
              nextSmsSeconds.map({ (0...2_678_400).contains($0) }) ?? true,
              nextCheckSeconds.map({ (0...2_678_400).contains($0) }) ?? true else { throw BConnectedEnrollmentError.invalidResponse }
        if state != .verification && state != .suspended {
            guard phoneVerified, nextSmsSeconds == nil, nextCheckSeconds == nil else { throw BConnectedEnrollmentError.invalidResponse }
        }
        if let metadata {
            _ = try BConnectedEnrollmentWire.uuid(metadata.memberId)
            _ = try BConnectedEnrollmentWire.uuid(metadata.account.aci)
            _ = try BConnectedEnrollmentWire.uuid(metadata.account.pni)
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            guard metadata.account.number == phone, metadata.account.deviceId == 1,
                  metadata.fullName.utf16.count <= 100, !metadata.fullName.isEmpty,
                  !metadata.fullName.unicodeScalars.contains(where: { $0.value < 32 || (127...159).contains($0.value) }),
                  (1940...calendar.component(.year, from: Date())).contains(metadata.graduationYear),
                  [.authorized, .recovering, .active, .suspended].contains(state) else { throw BConnectedEnrollmentError.invalidResponse }
        } else {
            guard memberId == nil, account == nil, fullName == nil, graduationYear == nil,
                  [.verification, .awaitingAuthorization, .suspended].contains(state) else { throw BConnectedEnrollmentError.invalidResponse }
        }
    }
    var enrollmentObservation: BConnectedEnrollmentObservation {
        .init(operationId: recoveryId, state: state == .active ? .active : state == .suspended ? .suspended : .pendingConfirmation,
              registrationAuthorized: registrationAuthorized, phoneVerified: phoneVerified, nextSmsSeconds: nextSmsSeconds,
              nextCheckSeconds: nextCheckSeconds, expiresInSeconds: expiresInSeconds, account: state == .active ? account : nil)
    }
}

public struct BConnectedRecoveryProgress {
    public let phone: String
    public let recoveryAttemptId: String
    public let observation: BConnectedRecoveryObservation?
    public let observedAt: Date?
    public let sendOutcomeUncertain: Bool
    public let replacementDispatched: Bool
}

enum BConnectedRecoveryOperation: String { case begin, sendCode = "send-code", checkCode = "check-code", status, complete }

struct BConnectedRecoveryJournal: Codable, CustomStringConvertible, CustomDebugStringConvertible {
    let version: Int
    let origin: String
    let attempt: String
    var observation: BConnectedRecoveryObservation?
    var metadata: BConnectedRecoveryObservation.Metadata?
    var observedAt: Date?
    var sendOutcomeUncertain = false
    var replacementDispatched = false
    var operatorCompletionObserved = false
    var description: String { "BConnectedRecoveryJournal(redacted)" }
    var debugDescription: String { description }

    func validate(material: BConnectedEnrollmentRecord) throws {
        guard version == 1, material.journalScope == .recovery, material.attempt == attempt,
              let url = URL(string: origin), try BConnectedOwnedOrigin.canonicalize(url).absoluteString == origin else {
            throw BConnectedEnrollmentError.persistenceUnavailable
        }
        try material.validate()
        if let observation {
            try observation.validate(phone: material.phone)
            guard observation.metadata == metadata, observedAt != nil,
                  ![.recovering, .active].contains(observation.state) || replacementDispatched || operatorCompletionObserved else { throw BConnectedEnrollmentError.persistenceUnavailable }
        } else if metadata != nil || observedAt != nil { throw BConnectedEnrollmentError.persistenceUnavailable }
        if operatorCompletionObserved {
            guard metadata != nil, let observation, [.recovering, .active, .suspended].contains(observation.state) else {
                throw BConnectedEnrollmentError.persistenceUnavailable
            }
        }
        if let metadata {
            guard material.binding == .init(memberId: metadata.memberId, challenge: attempt),
                  material.recoveryProfileName == metadata.fullName,
                  material.operationId == observation?.recoveryId else { throw BConnectedEnrollmentError.persistenceUnavailable }
        } else {
            guard material.binding == nil, material.operationId == nil, material.installedAccount == nil else { throw BConnectedEnrollmentError.persistenceUnavailable }
        }
    }
}

protocol BConnectedRecoveryPersistence {
    func transaction<T>(_ action: (inout BConnectedRecoveryJournal?, inout BConnectedEnrollmentRecord?) throws -> T) throws -> T
    func validateLocalBeforeReplacement(material: BConnectedEnrollmentRecord, account: BConnectedEnrollmentObservation.Account?) throws
}

final class BConnectedRecoveryStore: BConnectedRecoveryPersistence {
    private let db: any DB
    private let installer: BConnectedNativeAccountInstaller
    private let accountKeyStore: AccountKeyStore
    private let values = KeyValueStore(collection: BConnectedEnrollmentJournal.recovery.collection)
    init(db: any DB, installer: BConnectedNativeAccountInstaller, accountKeyStore: AccountKeyStore) {
        self.db = db; self.installer = installer; self.accountKeyStore = accountKeyStore
    }
    func transaction<T>(_ action: (inout BConnectedRecoveryJournal?, inout BConnectedEnrollmentRecord?) throws -> T) throws -> T {
        try db.writeWithRollbackIfThrows { tx in
            let originalJournal = values.getData("recovery", transaction: tx)
            let originalMaterial = values.getData("attempt", transaction: tx)
            var journal: BConnectedRecoveryJournal?
            var material: BConnectedEnrollmentRecord?
            do {
                journal = try originalJournal.map { try JSONDecoder().decode(BConnectedRecoveryJournal.self, from: $0) }
                material = try originalMaterial.map { try JSONDecoder().decode(BConnectedEnrollmentRecord.self, from: $0) }
                if let journal, let material { try journal.validate(material: material) }
                else if journal != nil || material != nil { throw BConnectedEnrollmentError.persistenceUnavailable }
            } catch { throw BConnectedEnrollmentError.persistenceUnavailable }
            let result = try action(&journal, &material)
            guard let journal, let material else {
                guard originalJournal == nil, originalMaterial == nil, journal == nil, material == nil else { throw BConnectedEnrollmentError.persistenceUnavailable }
                return result
            }
            try journal.validate(material: material)
            let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
            let journalBytes = try encoder.encode(journal), materialBytes = try encoder.encode(material)
            if journalBytes != originalJournal { values.setData(journalBytes, key: "recovery", transaction: tx) }
            if materialBytes != originalMaterial { values.setData(materialBytes, key: "attempt", transaction: tx) }
            return result
        }
    }

    func validateLocalBeforeReplacement(material: BConnectedEnrollmentRecord, account: BConnectedEnrollmentObservation.Account?) throws {
        try db.writeWithRollbackIfThrows { tx in
            guard let bytes = values.getData("attempt", transaction: tx),
                  try BConnectedRecoveryWire.encoded(JSONDecoder().decode(BConnectedEnrollmentRecord.self, from: bytes)) == BConnectedRecoveryWire.encoded(material) else {
                throw BConnectedEnrollmentError.immutableConflict
            }
            try Self.validateNoPriorSessions(tx: tx)
            try installer.validateRecoveryPrerequisites(record: material, account: account, tx: tx)
            try accountKeyStore.validateBConnectedEmptyEntropy(tx: tx)
            if let account {
                let candidates = try SignalRecipient.filter(
                    Column(SignalRecipient.CodingKeys.aciString.rawValue) == account.aci.uppercased()
                    || Column(SignalRecipient.CodingKeys.pni.rawValue) == "PNI:" + account.pni.uppercased()
                    || Column(SignalRecipient.CodingKeys.phoneNumber.rawValue) == account.number
                ).fetchAll(tx.database)
                guard candidates.isEmpty else { throw BConnectedEnrollmentError.immutableConflict }
            }
        }
    }

    static func validateNoPriorSessions(tx: DBReadTransaction) throws {
        // Existence checks read no message/key bytes and never reset old ratchets.
        for table in [SessionRecord.databaseTableName, SenderKeyRecord.databaseTableName, SenderKeySentToDeviceRecord.databaseTableName] {
            guard try Bool.fetchOne(tx.database, sql: "SELECT EXISTS (SELECT 1 FROM \"\(table)\")") == false else {
                throw BConnectedEnrollmentError.immutableConflict
            }
        }
    }
}

protocol BConnectedRecoverySending {
    func send(_ operation: BConnectedRecoveryOperation, journal: BConnectedRecoveryJournal,
              material: BConnectedEnrollmentRecord, code: String?) async throws -> BConnectedRecoveryObservation
}

enum BConnectedRecoveryWire {
    static func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return try encoder.encode(value)
    }
    static func response(_ data: Data, status: Int, expectedId: String?, phone: String) throws -> BConnectedRecoveryObservation {
        do {
            let root = try BConnectedEnrollmentWire.object(data)
            if status != 200 && status != 202 {
                let error = try BConnectedEnrollmentWire.fields(root, required: ["code"], optional: ["retryAfterSeconds"])
                guard let code = BConnectedEnrollmentError.Code(rawValue: try BConnectedEnrollmentWire.text(error["code"])) else { throw BConnectedEnrollmentError.invalidResponse }
                let statuses: [BConnectedEnrollmentError.Code: Int] = [.invalidRequest: 400, .invalidCredentials: 401,
                    .recoveryUnavailable: 404, .recoveryConflict: 409, .recoveryExpired: 410, .recoveryNotAuthorized: 403,
                    .codeNotAccepted: 422, .codeExpired: 422, .rateLimited: 429, .temporarilyUnavailable: 503]
                guard statuses[code] == status else { throw BConnectedEnrollmentError.invalidResponse }
                let retry = try error["retryAfterSeconds"].map(BConnectedEnrollmentWire.integer)
                guard retry.map({ (0...86_400).contains($0) }) ?? true else { throw BConnectedEnrollmentError.invalidResponse }
                throw BConnectedEnrollmentError.rejected(code, retryAfterSeconds: retry)
            }
            _ = try BConnectedEnrollmentWire.fields(root, required: ["recoveryId", "state", "phoneVerified", "nextSmsSeconds", "nextCheckSeconds", "expiresInSeconds", "registrationAuthorized", "memberId", "account", "fullName", "graduationYear"])
            for key in ["phoneVerified", "registrationAuthorized"] { _ = try BConnectedEnrollmentWire.boolean(root[key]) }
            for key in ["nextSmsSeconds", "nextCheckSeconds", "expiresInSeconds", "graduationYear"] {
                if !(root[key] is NSNull) { _ = try BConnectedEnrollmentWire.integer(root[key]) }
            }
            if !(root["account"] is NSNull) {
                let account = try BConnectedEnrollmentWire.fields(root["account"], required: ["aci", "pni", "number", "deviceId"])
                _ = try BConnectedEnrollmentWire.integer(account["deviceId"])
            }
            let observation = try JSONDecoder().decode(BConnectedRecoveryObservation.self, from: data)
            try observation.validate(phone: phone)
            guard expectedId == nil || observation.recoveryId == expectedId,
                  status == 200 || observation.state == .recovering else { throw BConnectedEnrollmentError.invalidResponse }
            return observation
        } catch let error as BConnectedEnrollmentError {
            if case .rejected = error { throw error }
            throw BConnectedEnrollmentError.invalidResponse
        } catch { throw BConnectedEnrollmentError.invalidResponse }
    }
}

final class BConnectedRecoveryClient: BConnectedRecoverySending {
    private let endpoint: BConnectedEnrollmentEndpoint
    private let http: any BConnectedOwnedHTTPSending
    init(endpoint: BConnectedEnrollmentEndpoint, http: any BConnectedOwnedHTTPSending = BConnectedOwnedHTTP()) {
        self.endpoint = endpoint; self.http = http
    }
    func request(_ operation: BConnectedRecoveryOperation, journal: BConnectedRecoveryJournal,
                 material: BConnectedEnrollmentRecord, code: String?) throws -> URLRequest {
        try journal.validate(material: material)
        guard journal.origin == endpoint.origin.absoluteString else { throw BConnectedEnrollmentError.immutableConflict }
        var components = URLComponents(url: endpoint.origin, resolvingAgainstBaseURL: false)!
        if operation == .begin { components.path = "/v1/bconnected/recovery/begin" }
        else {
            guard let id = journal.observation?.recoveryId else { throw BConnectedEnrollmentError.operationRequired }
            components.path = "/v1/bconnected/recovery/" + id + "/" + operation.rawValue
        }
        var body: [String: Any] = ["recoveryAttemptId": material.attempt,
            "registrationRequest": try BConnectedEnrollmentWire.object(material.registrationRequest),
            "originalSignalAgent": material.originalSignalAgent, "originalUserAgent": material.originalUserAgent]
        if operation == .checkCode {
            guard let code, (4...10).contains(code.utf8.count), code.utf8.allSatisfy({ (48...57).contains($0) }) else { throw BConnectedEnrollmentError.invalidInput }
            body["code"] = code
        } else if code != nil { throw BConnectedEnrollmentError.invalidInput }
        var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "POST"; request.httpBody = try BConnectedEnrollmentWire.encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("Basic " + Data((material.phone + ":" + material.password).utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        request.setValue(material.originalUserAgent, forHTTPHeaderField: "User-Agent")
        return request
    }
    func send(_ operation: BConnectedRecoveryOperation, journal: BConnectedRecoveryJournal,
              material: BConnectedEnrollmentRecord, code: String?) async throws -> BConnectedRecoveryObservation {
        let (data, status) = try await http.send(request(operation, journal: journal, material: material, code: code))
        return try BConnectedRecoveryWire.response(data, status: status, expectedId: journal.observation?.recoveryId, phone: material.phone)
    }
}

/// All requests reuse the original durable material. Status cannot initiate replacement or SMS.
@MainActor
final class BConnectedRecoveryTransport {
    let persistence: any BConnectedRecoveryPersistence
    let client: any BConnectedRecoverySending
    init(persistence: any BConnectedRecoveryPersistence, client: any BConnectedRecoverySending) {
        self.persistence = persistence; self.client = client
    }
    func perform(_ operation: BConnectedRecoveryOperation, code: String? = nil) async throws -> BConnectedRecoveryObservation {
        let snapshot = try persistence.transaction { journal, material in
            guard var saved = journal, let material else { throw BConnectedEnrollmentError.missingAttempt }
            try saved.validate(material: material)
            if operation == .sendCode { saved.sendOutcomeUncertain = true }
            if operation == .complete { saved.replacementDispatched = true }
            journal = saved
            return (saved, material)
        }
        try Task.checkCancellation()
        let response = try await client.send(operation, journal: snapshot.0, material: snapshot.1, code: code)
        return try persistence.transaction { journal, material in
            guard var saved = journal, var current = material, current.attempt == snapshot.1.attempt,
                  current.password == snapshot.1.password, current.registrationRequest == snapshot.1.registrationRequest,
                  saved.origin == snapshot.0.origin,
                  saved.observation?.recoveryId == snapshot.0.observation?.recoveryId else { throw BConnectedEnrollmentError.immutableConflict }
            try response.validate(phone: current.phone)
            let observesReplacement = [.recovering, .active].contains(response.state)
            // An operator may finish this exact request only after this device has
            // durably observed its authorized account binding. Never accept an
            // unsolicited ACTIVE first response as permission to install credentials.
            let knownAuthorization = saved.metadata != nil && saved.observation.map {
                [.authorized, .recovering, .active].contains($0.state)
            } == true
            guard saved.observation == nil || saved.observation?.recoveryId == response.recoveryId,
                  saved.metadata == nil || saved.metadata == response.metadata,
                  saved.observation?.phoneVerified != true || response.phoneVerified,
                  saved.observation?.state != .suspended || response.state == .suspended,
                  !observesReplacement || saved.replacementDispatched || knownAuthorization else { throw BConnectedEnrollmentError.invalidResponse }
            if observesReplacement && !saved.replacementDispatched { saved.operatorCompletionObserved = true }
            if let metadata = response.metadata {
                saved.metadata = metadata
                current.binding = .init(memberId: metadata.memberId, challenge: current.attempt)
                current.operationId = response.recoveryId
                current.recoveryProfileName = metadata.fullName
                current.observation = response.enrollmentObservation
            }
            saved.observation = response; saved.observedAt = Date()
            if operation == .sendCode { saved.sendOutcomeUncertain = false }
            journal = saved; material = current
            return response
        }
    }
}

@MainActor
private final class BConnectedRecoveryStatusAdapter: BConnectedEnrollmentSending {
    let transport: BConnectedRecoveryTransport
    init(transport: BConnectedRecoveryTransport) { self.transport = transport }
    func send(_ operation: BConnectedEnrollmentOperation, record: BConnectedEnrollmentRecord, code: String?) async throws -> BConnectedEnrollmentObservation {
        guard operation == .status, code == nil, record.journalScope == .recovery else { throw BConnectedEnrollmentError.invalidInput }
        return try await transport.perform(.status).enrollmentObservation
    }
}

@MainActor
public final class BConnectedRecoveryCoordinator {
    private let endpoint: BConnectedEnrollmentEndpoint
    private let transport: BConnectedRecoveryTransport
    private let native: BConnectedEnrollmentCoordinator
    private var inFlight = false
    init(endpoint: BConnectedEnrollmentEndpoint, persistence: any BConnectedRecoveryPersistence,
         client: any BConnectedRecoverySending, native: BConnectedEnrollmentCoordinator) {
        self.endpoint = endpoint; self.transport = .init(persistence: persistence, client: client); self.native = native
    }
    public init(db: any DB, endpoint: BConnectedEnrollmentEndpoint, nativeInstaller: BConnectedNativeAccountInstaller,
                accountKeyStore: AccountKeyStore, udManager: OWSUDManager, dmAlphaConfiguration: BConnectedDMAlphaConfiguration) {
        self.endpoint = endpoint
        let persistence = BConnectedRecoveryStore(db: db, installer: nativeInstaller, accountKeyStore: accountKeyStore)
        let transport = BConnectedRecoveryTransport(persistence: persistence, client: BConnectedRecoveryClient(endpoint: endpoint))
        self.transport = transport
        self.native = BConnectedEnrollmentCoordinator(persistence: BConnectedEnrollmentStore(db: db, nativeInstaller: nativeInstaller,
            accountKeyStore: accountKeyStore, publicationConfiguration: dmAlphaConfiguration.publication, udManager: udManager, journal: .recovery),
            client: BConnectedRecoveryStatusAdapter(transport: transport), publicationConfiguration: dmAlphaConfiguration.publication,
            publisher: BConnectedPublicationClient(), preKeyPublisher: BConnectedPreKeyClient(), acceptanceReader: BConnectedAccountAcceptanceClient(),
            dmAlphaConfiguration: dmAlphaConfiguration)
    }
    public func progress() throws -> BConnectedRecoveryProgress? {
        try transport.persistence.transaction { journal, material in
            guard let journal, let material else { return nil }
            guard journal.origin == endpoint.origin.absoluteString else { throw BConnectedEnrollmentError.immutableConflict }
            return .init(phone: material.phone, recoveryAttemptId: material.attempt, observation: journal.observation,
                observedAt: journal.observedAt, sendOutcomeUncertain: journal.sendOutcomeUncertain, replacementDispatched: journal.replacementDispatched)
        }
    }
    public func prepare(_ input: BConnectedEnrollmentPreparation) throws {
        guard !inFlight else { throw BConnectedEnrollmentError.busy }
        let material = try transport.persistence.transaction { journal, material in
            if let journal, let material {
                guard material.phone == input.phone, journal.origin == endpoint.origin.absoluteString else { throw BConnectedEnrollmentError.immutableConflict }
                return material
            }
            var generated = try BConnectedEnrollmentRecord.generate(input); generated.journal = .recovery
            material = generated
            journal = .init(version: 1, origin: endpoint.origin.absoluteString, attempt: generated.attempt)
            return generated
        }
        try transport.persistence.validateLocalBeforeReplacement(material: material, account: nil)
    }
    public func refresh() async throws {
        guard !inFlight else { throw BConnectedEnrollmentError.busy }
        inFlight = true; defer { inFlight = false }
        let progress = try progress()
        guard progress != nil else { throw BConnectedEnrollmentError.missingAttempt }
        _ = try await transport.perform(progress?.observation == nil ? .begin : .status)
    }
    public func sendCode(confirmedUncertain: Bool, mayDispatch: () -> Bool) async throws {
        guard !inFlight else { throw BConnectedEnrollmentError.busy }
        inFlight = true; defer { inFlight = false }
        let before = try progress()
        guard before != nil, before?.sendOutcomeUncertain != true || confirmedUncertain else { throw BConnectedEnrollmentError.explicitSendRequired }
        let fresh = try await transport.perform(before?.observation == nil ? .begin : .status)
        try Task.checkCancellation()
        guard mayDispatch(), fresh.state == .verification, !fresh.phoneVerified, fresh.nextSmsSeconds == 0 else { throw BConnectedEnrollmentError.unavailable }
        _ = try await transport.perform(.sendCode)
    }
    public func checkCode(_ code: String) async throws {
        guard !inFlight else { throw BConnectedEnrollmentError.busy }
        inFlight = true; defer { inFlight = false }
        let fresh = try await transport.perform(.status)
        try Task.checkCancellation()
        guard fresh.state == .verification, !fresh.phoneVerified, fresh.nextCheckSeconds == 0 else { return }
        _ = try await transport.perform(.checkCode, code: code)
    }
    public func replaceAccount(mayDispatch: () -> Bool) async throws {
        guard !inFlight else { throw BConnectedEnrollmentError.busy }
        inFlight = true; defer { inFlight = false }
        let fresh = try await transport.perform(.status)
        try Task.checkCancellation()
        guard mayDispatch(), fresh.state == .authorized, let account = fresh.account else { throw BConnectedEnrollmentError.unavailable }
        let material = try transport.persistence.transaction { _, material in
            guard let material else { throw BConnectedEnrollmentError.missingAttempt }; return material
        }
        try transport.persistence.validateLocalBeforeReplacement(material: material, account: account)
        try Task.checkCancellation()
        guard mayDispatch() else { throw CancellationError() }
        _ = try await transport.perform(.complete)
    }
    public func finishLocalSetup(explicitRetry: Bool) async throws {
        guard !inFlight else { throw BConnectedEnrollmentError.busy }
        inFlight = true; defer { inFlight = false }
        let fresh = try await transport.perform(.status)
        guard fresh.state == .active, fresh.registrationAuthorized else { throw BConnectedEnrollmentError.unavailable }
        try Task.checkCancellation()
        if try native.progress()?.nativeAccountInstalled != true {
            let material = try transport.persistence.transaction { _, material in
                guard let material else { throw BConnectedEnrollmentError.missingAttempt }; return material
            }
            try transport.persistence.validateLocalBeforeReplacement(material: material, account: fresh.account)
            try Task.checkCancellation()
            try await native.installNativeAccount()
        }
        try Task.checkCancellation(); try native.prepareLocalAccount(); try native.prepareAccountEntropy()
        try Task.checkCancellation(); try await native.publishAccount(explicitlyRetryUncertainOutcome: explicitRetry)
        try Task.checkCancellation(); try await native.publishPreKeys()
        try Task.checkCancellation(); try await native.completeDMAlpha()
    }
}
