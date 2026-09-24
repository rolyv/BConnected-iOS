// Copyright 2026 BConnected contributors. SPDX-License-Identifier: AGPL-3.0-only

public import Foundation
import Security

public struct BConnectedCommunityMember: Codable, Equatable {
    public enum Status: String, Codable { case pending, approved, rejected, suspended }
    public let id: String
    public let fullName: String
    public let graduationYear: Int
    public let status: Status
}

/// An editable draft in the encrypted application database; never an application or authorization.
public struct BConnectedSignupDraft: Codable, Equatable {
    public var phone: String
    public var region: String
    public var name: String
    public var year: String
    public init(phone: String = "", region: String = "US", name: String = "", year: String = "") {
        self.phone = phone; self.region = region; self.name = name; self.year = year
    }
}

public struct BConnectedCommunityProgress {
    public let member: BConnectedCommunityMember?
    public let applicationOutcomeUncertain: Bool
    public let savedApplicationPhone: String?
    public let savedApplicationName: String?
    public let savedApplicationYear: Int?
    public let phoneSignup: BConnectedPhoneSignupProgress?
    public let canRestartPhoneSetup: Bool
    public let intentOutcomeUncertain: Bool
    public let intentRetryNotBefore: Date?
}

public struct BConnectedPhoneSignupProgress {
    public let hasChallenge: Bool
    public let hasOperation: Bool
    public let phoneVerified: Bool
    public let smsOutcomeNeedsExplicitDecision: Bool
    public let nextSmsSeconds: Int?
    public let nextCheckSeconds: Int?
    /// Receipt time is durable. An elapsed deadline only schedules a fresh status read.
    public let observedAt: Date?
}

public struct BConnectedPhoneSignupObservation: Codable, Equatable {
    public let operationId: String
    public let phoneVerified: Bool
    public let nextSmsSeconds: Int?
    public let nextCheckSeconds: Int?
    public let expiresInSeconds: Int
}

struct BConnectedCommunityRecord: Codable, CustomStringConvertible, CustomDebugStringConvertible {
    var description: String { "BConnectedCommunityRecord(redacted)" }
    var debugDescription: String { description }
    struct Session: Codable { let token: String; let expiresAt: Int; var member: BConnectedCommunityMember }
    struct Binding: Codable { let memberId: String; let bindingChallenge: String; let expiresAt: Int }
    /// Frozen before the first request, so an uncertain response can be retried idempotently.
    /// Optional to preserve version-one invitation sessions already on devices.
    struct PhoneApplication: Codable, Equatable {
        let phone: String
        let fullName: String
        let graduationYear: Int
        let nonce: String
        let createdAtMillis: Int?
    }
    struct PhoneChallenge: Codable, Equatable {
        let applicationId: String
        let expiresAt: Int
    }
    struct PhoneSignup: Codable, Equatable {
        var operationId: String?
        var observation: BConnectedPhoneSignupObservation?
        var sendNeedsExplicitDecision = false
        var observedAt: Date?
    }
    var draft: BConnectedSignupDraft?
    var version = 1
    var applicationDispatched = false
    var phoneApplication: PhoneApplication?
    var phoneChallenge: PhoneChallenge?
    var phoneSignup: PhoneSignup?
    var session: Session?
    var intentRetryNotBefore: Date?
    var binding: Binding?

    func validate() throws {
        guard version == 1 else { throw BConnectedEnrollmentError.persistenceUnavailable }
        if let phoneApplication {
            try BConnectedEnrollmentWire.phone(phoneApplication.phone)
            _ = try BConnectedEnrollmentWire.metadata(phoneApplication.fullName, limit: 400)
            _ = try BConnectedEnrollmentWire.nonce(phoneApplication.nonce)
            if let createdAtMillis = phoneApplication.createdAtMillis {
                guard createdAtMillis > 0 else { throw BConnectedEnrollmentError.persistenceUnavailable }
            }
            guard applicationDispatched, !phoneApplication.fullName.isEmpty,
                  phoneApplication.fullName == phoneApplication.fullName.trimmingCharacters(in: .whitespacesAndNewlines),
                  phoneApplication.fullName.utf16.count <= 100,
                  (1940...9999).contains(phoneApplication.graduationYear) else {
                throw BConnectedEnrollmentError.persistenceUnavailable
            }
            if let session {
                guard session.token == phoneApplication.nonce,
                      session.member.fullName == phoneApplication.fullName,
                      session.member.graduationYear == phoneApplication.graduationYear,
                      phoneSignup?.observation?.phoneVerified == true else {
                    throw BConnectedEnrollmentError.persistenceUnavailable
                }
            }
        }
        if let phoneChallenge {
            guard phoneApplication != nil, phoneChallenge.expiresAt > 0 else { throw BConnectedEnrollmentError.persistenceUnavailable }
            _ = try BConnectedEnrollmentWire.uuid(phoneChallenge.applicationId)
        }
        if let phoneSignup {
            guard let phoneChallenge else { throw BConnectedEnrollmentError.persistenceUnavailable }
            if let operationId = phoneSignup.operationId {
                guard try BConnectedEnrollmentWire.uuid(operationId) == phoneChallenge.applicationId else {
                    throw BConnectedEnrollmentError.persistenceUnavailable
                }
            }
            if let observation = phoneSignup.observation {
                guard observation.operationId == phoneSignup.operationId else { throw BConnectedEnrollmentError.persistenceUnavailable }
            }
        }
        if let session {
            _ = try BConnectedEnrollmentWire.nonce(session.token)
            _ = try BConnectedCommunityWire.member(JSONSerialization.jsonObject(with: JSONEncoder().encode(session.member)))
            guard session.expiresAt > 0, applicationDispatched else { throw BConnectedEnrollmentError.persistenceUnavailable }
        }
        if let binding {
            guard session?.member.id == binding.memberId, binding.expiresAt > 0 else { throw BConnectedEnrollmentError.persistenceUnavailable }
            _ = try BConnectedEnrollmentWire.nonce(binding.bindingChallenge)
        }
    }
}

protocol BConnectedCommunityPersistence {
    func transaction<T>(_ update: (inout BConnectedCommunityRecord) throws -> T) throws -> T
}

protocol BConnectedCommunitySending {
    func enroll(name: String, year: Int, invite: String) async throws -> BConnectedCommunityRecord.Session
    func enrollPhone(_ application: BConnectedCommunityRecord.PhoneApplication) async throws -> BConnectedCommunityRecord.PhoneChallenge
    func phoneStatus(nonce: String) async throws -> BConnectedPhoneCommunityStatus
    func member(token: String) async throws -> BConnectedCommunityMember
    func intent(token: String, material: BConnectedEnrollmentIntentMaterial) async throws -> BConnectedCommunityRecord.Binding
}

enum BConnectedPhoneCommunityStatus {
    case challenge(BConnectedCommunityRecord.PhoneChallenge)
    case verified(BConnectedCommunityRecord.Session)
}

enum BConnectedPhoneSignupOperation: String { case begin, sendCode = "send-code", checkCode = "check-code", status }
protocol BConnectedPhoneSignupSending {
    func send(_ operation: BConnectedPhoneSignupOperation, application: BConnectedCommunityRecord.PhoneApplication,
              challenge: BConnectedCommunityRecord.PhoneChallenge, code: String?) async throws -> BConnectedPhoneSignupObservation
}

enum BConnectedCommunityWire {
    static func member(_ value: Any) throws -> BConnectedCommunityMember {
        let root = try BConnectedEnrollmentWire.fields(value, required: ["id", "fullName", "graduationYear", "status"])
        let id = try BConnectedEnrollmentWire.uuid(root["id"])
        let name = try BConnectedEnrollmentWire.metadata(root["fullName"], limit: 400)
        let year = try BConnectedEnrollmentWire.integer(root["graduationYear"])
        guard (1940...9999).contains(year), let status = BConnectedCommunityMember.Status(rawValue: try BConnectedEnrollmentWire.text(root["status"])) else { throw BConnectedEnrollmentError.invalidResponse }
        return .init(id: id, fullName: name, graduationYear: year, status: status)
    }
}

final class BConnectedCommunityClient: BConnectedCommunitySending {
    private let endpoint: BConnectedEnrollmentEndpoint
    private let http: any BConnectedOwnedHTTPSending
    init(endpoint: BConnectedEnrollmentEndpoint, http: any BConnectedOwnedHTTPSending = BConnectedOwnedHTTP()) {
        self.endpoint = endpoint; self.http = http
    }
    private func request(path: String, method: String, token: String? = nil, body: [String: Any]? = nil, expectedStatus: Int) async throws -> [String: Any] {
        var components = URLComponents(url: endpoint.origin, resolvingAgainstBaseURL: false)!
        components.path = path
        guard let url = components.url else { throw BConnectedEnrollmentError.invalidInput }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if let token { _ = try BConnectedEnrollmentWire.nonce(token); request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if let body { request.httpBody = try BConnectedEnrollmentWire.encode(body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, status) = try await http.send(request)
        if path == "/v1/enroll/phone", status == 409,
           let rejection = try? BConnectedEnrollmentWire.object(data),
           Set(rejection.keys) == ["error"],
           rejection["error"] as? String == "Enrollment unavailable" {
            throw BConnectedEnrollmentError.phoneEnrollmentRejected
        }
        // Existing community API has untyped errors. Keep them unavailable; never infer bad credentials
        // from an IAM/proxy rejection or expose raw backend messages. Do not erase the session.
        guard status == expectedStatus else { throw BConnectedEnrollmentError.unavailable }
        return try BConnectedEnrollmentWire.object(data)
    }
    func enroll(name: String, year: Int, invite: String) async throws -> BConnectedCommunityRecord.Session {
        let result = try await request(path: "/v1/enroll", method: "POST", body: ["fullName": name, "graduationYear": year, "inviteCode": invite], expectedStatus: 201)
        let root = try BConnectedEnrollmentWire.fields(result, required: ["token", "expiresAt", "member"])
        let token = try BConnectedEnrollmentWire.nonce(root["token"])
        let expiry = try BConnectedEnrollmentWire.integer(root["expiresAt"])
        let member = try BConnectedCommunityWire.member(root["member"]!)
        guard expiry > 0, member.status == .pending else { throw BConnectedEnrollmentError.invalidResponse }
        return .init(token: token, expiresAt: expiry, member: member)
    }
    private func phoneChallenge(_ result: [String: Any]) throws -> BConnectedCommunityRecord.PhoneChallenge {
        do {
            let root = try BConnectedEnrollmentWire.fields(result, required: ["applicationId", "expiresAt", "status"])
            guard try BConnectedEnrollmentWire.text(root["status"]) == "phone_verification_required" else {
                throw BConnectedEnrollmentError.invalidResponse
            }
            let expiry = try BConnectedEnrollmentWire.integer(root["expiresAt"])
            guard expiry > 0 else { throw BConnectedEnrollmentError.invalidResponse }
            return .init(applicationId: try BConnectedEnrollmentWire.uuid(root["applicationId"]), expiresAt: expiry)
        } catch { throw BConnectedEnrollmentError.invalidResponse }
    }
    func enrollPhone(_ application: BConnectedCommunityRecord.PhoneApplication) async throws -> BConnectedCommunityRecord.PhoneChallenge {
        let result = try await request(path: "/v1/enroll/phone", method: "POST", body: [
            "phoneNumber": application.phone,
            "fullName": application.fullName,
            "graduationYear": application.graduationYear,
            "enrollmentNonce": application.nonce
        ], expectedStatus: 201)
        return try phoneChallenge(result)
    }
    func phoneStatus(nonce: String) async throws -> BConnectedPhoneCommunityStatus {
        let result = try await request(path: "/v1/enroll/phone/status", method: "GET", token: nonce, expectedStatus: 200)
        if result["status"] != nil { return .challenge(try phoneChallenge(result)) }
        do {
            let root = try BConnectedEnrollmentWire.fields(result, required: ["token", "expiresAt", "member"])
            let token = try BConnectedEnrollmentWire.nonce(root["token"])
            let expiry = try BConnectedEnrollmentWire.integer(root["expiresAt"])
            let member = try BConnectedCommunityWire.member(root["member"]!)
            guard token == nonce, expiry > 0,
                  member.status == .approved || member.status == .pending else {
                throw BConnectedEnrollmentError.invalidResponse
            }
            return .verified(.init(token: token, expiresAt: expiry, member: member))
        } catch { throw BConnectedEnrollmentError.invalidResponse }
    }
    func member(token: String) async throws -> BConnectedCommunityMember {
        try BConnectedCommunityWire.member(await request(path: "/v1/me", method: "GET", token: token, expectedStatus: 200))
    }
    func intent(token: String, material: BConnectedEnrollmentIntentMaterial) async throws -> BConnectedCommunityRecord.Binding {
        let result = try await request(path: "/v1/admission/intents", method: "POST", token: token,
                                       body: ["registrationAttemptId": material.registrationAttemptId, "deviceKeyCommitment": material.keyCommitment], expectedStatus: 201)
        let root = try BConnectedEnrollmentWire.fields(result, required: ["memberId", "bindingChallenge", "expiresAt", "status", "registrationAuthorized"])
        guard try BConnectedEnrollmentWire.text(root["status"]) == "awaiting_signal_claim",
              try !BConnectedEnrollmentWire.boolean(root["registrationAuthorized"]) else { throw BConnectedEnrollmentError.invalidResponse }
        let expiry = try BConnectedEnrollmentWire.integer(root["expiresAt"])
        guard expiry > 0 else { throw BConnectedEnrollmentError.invalidResponse }
        return .init(memberId: try BConnectedEnrollmentWire.uuid(root["memberId"]), bindingChallenge: try BConnectedEnrollmentWire.nonce(root["bindingChallenge"]), expiresAt: expiry)
    }
}

final class BConnectedPhoneSignupClient: BConnectedPhoneSignupSending {
    private let endpoint: BConnectedEnrollmentEndpoint
    private let http: any BConnectedOwnedHTTPSending
    init(endpoint: BConnectedEnrollmentEndpoint, http: any BConnectedOwnedHTTPSending = BConnectedOwnedHTTP()) {
        self.endpoint = endpoint; self.http = http
    }

    func send(_ operation: BConnectedPhoneSignupOperation, application: BConnectedCommunityRecord.PhoneApplication,
              challenge: BConnectedCommunityRecord.PhoneChallenge, code: String?) async throws -> BConnectedPhoneSignupObservation {
        var components = URLComponents(url: endpoint.origin, resolvingAgainstBaseURL: false)!
        components.path = operation == .begin ? "/v1/bconnected/signup/begin"
            : "/v1/bconnected/signup/\(challenge.applicationId)/\(operation.rawValue)"
        guard let url = components.url else { throw BConnectedEnrollmentError.invalidInput }
        var body: [String: Any] = ["applicationId": challenge.applicationId,
                                  "enrollmentNonce": application.nonce,
                                  "phoneNumber": application.phone]
        if operation == .checkCode {
            guard let code, code.range(of: #"^[0-9]{4,10}$"#, options: .regularExpression) != nil else {
                throw BConnectedEnrollmentError.invalidInput
            }
            body["code"] = code
        } else if code != nil { throw BConnectedEnrollmentError.invalidInput }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.httpBody = try BConnectedEnrollmentWire.encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        let (data, status) = try await http.send(request)
        if operation == .status, status == 404,
           let rejection = try? BConnectedEnrollmentWire.object(data),
           Set(rejection.keys) == ["code"],
           rejection["code"] as? String == BConnectedEnrollmentError.Code.enrollmentUnavailable.rawValue {
            // The owned signup API uses this exact response only when BEGIN never ran.
            // Any other response is ambiguous and must not authorize BEGIN or an SMS.
            throw BConnectedEnrollmentError.rejected(.enrollmentUnavailable, retryAfterSeconds: nil)
        }
        if status != 200 {
            // Only the exact missing-operation envelope above can authorize a later BEGIN.
            if operation == .status && status == 404 { throw BConnectedEnrollmentError.unavailable }
            guard let root = try? BConnectedEnrollmentWire.fields(BConnectedEnrollmentWire.object(data), required: ["code"], optional: ["retryAfterSeconds"]),
                  let raw = root["code"] as? String, let code = BConnectedEnrollmentError.Code(rawValue: raw) else {
                throw BConnectedEnrollmentError.unavailable
            }
            let statuses: [BConnectedEnrollmentError.Code: Int] = [.invalidRequest: 400, .invalidCredentials: 401,
                .enrollmentUnavailable: 404, .enrollmentConflict: 409, .enrollmentExpired: 410,
                .codeNotAccepted: 422, .codeExpired: 422, .rateLimited: 429, .temporarilyUnavailable: 503]
            guard statuses[code] == status else { throw BConnectedEnrollmentError.invalidResponse }
            guard code != .codeExpired || (operation == .checkCode && Set(root.keys) == ["code"]) else {
                throw BConnectedEnrollmentError.invalidResponse
            }
            let retry: Int?
            if let value = root["retryAfterSeconds"], !(value is NSNull) {
                guard let seconds = try? BConnectedEnrollmentWire.integer(value), seconds >= 0 else {
                    throw BConnectedEnrollmentError.invalidResponse
                }
                retry = seconds
            } else { retry = nil }
            throw BConnectedEnrollmentError.rejected(code, retryAfterSeconds: retry)
        }
        do {
            let root = try BConnectedEnrollmentWire.fields(BConnectedEnrollmentWire.object(data),
                required: ["operationId", "state", "phoneVerified", "nextSmsSeconds", "nextCheckSeconds", "expiresInSeconds", "registrationAuthorized"])
            guard try BConnectedEnrollmentWire.uuid(root["operationId"]) == challenge.applicationId,
                  try BConnectedEnrollmentWire.text(root["state"]) == "verification",
                  try !BConnectedEnrollmentWire.boolean(root["registrationAuthorized"]) else {
                throw BConnectedEnrollmentError.invalidResponse
            }
            func cooldown(_ value: Any?) throws -> Int? {
                if value is NSNull { return nil }
                let seconds = try BConnectedEnrollmentWire.integer(value)
                guard seconds >= 0 else { throw BConnectedEnrollmentError.invalidResponse }
                return seconds
            }
            let nextSms = try cooldown(root["nextSmsSeconds"])
            let nextCheck = try cooldown(root["nextCheckSeconds"])
            let expires = try BConnectedEnrollmentWire.integer(root["expiresInSeconds"])
            guard expires > 0 else { throw BConnectedEnrollmentError.invalidResponse }
            return .init(operationId: challenge.applicationId,
                         phoneVerified: try BConnectedEnrollmentWire.boolean(root["phoneVerified"]),
                         nextSmsSeconds: nextSms, nextCheckSeconds: nextCheck, expiresInSeconds: expires)
        } catch { throw BConnectedEnrollmentError.invalidResponse }
    }
}

@MainActor
public final class BConnectedCommunityEnrollmentCoordinator {
    private let persistence: any BConnectedCommunityPersistence
    private let client: any BConnectedCommunitySending
    private let signup: (any BConnectedPhoneSignupSending)?
    private let enrollment: BConnectedEnrollmentCoordinator
    private let now: () -> Date
    private var inFlight = false

    init(persistence: any BConnectedCommunityPersistence, client: any BConnectedCommunitySending,
         signup: (any BConnectedPhoneSignupSending)? = nil,
         enrollment: BConnectedEnrollmentCoordinator, now: @escaping () -> Date = Date.init) {
        self.persistence = persistence; self.client = client; self.signup = signup; self.enrollment = enrollment; self.now = now
    }

    public func progress() throws -> BConnectedCommunityProgress {
        let record = try persistence.transaction { $0 }
        try record.validate()
        let mayRestart: Bool
        if let challenge = record.phoneChallenge, record.phoneApplication != nil,
           record.session == nil, record.phoneSignup?.operationId == nil,
           record.phoneSignup?.observation?.phoneVerified != true,
           challenge.expiresAt <= Int(now().timeIntervalSince1970 * 1000),
           record.binding == nil, record.intentRetryNotBefore == nil {
            mayRestart = try enrollment.progress() == nil
        } else { mayRestart = false }
        let phoneSignup: BConnectedPhoneSignupProgress?
        if record.phoneChallenge != nil {
            let observation = record.phoneSignup?.observation
            phoneSignup = .init(hasChallenge: true, hasOperation: record.phoneSignup?.operationId != nil,
                                phoneVerified: observation?.phoneVerified == true,
                                smsOutcomeNeedsExplicitDecision: record.phoneSignup?.sendNeedsExplicitDecision == true,
                                nextSmsSeconds: record.phoneSignup?.operationId == nil ? 0 : observation?.nextSmsSeconds,
                                nextCheckSeconds: observation?.nextCheckSeconds,
                                observedAt: record.phoneSignup?.observedAt)
        } else { phoneSignup = nil }
        return .init(member: record.session?.member,
                     applicationOutcomeUncertain: record.applicationDispatched && record.session == nil && record.phoneChallenge == nil,
                     savedApplicationPhone: record.phoneApplication?.phone,
                     savedApplicationName: record.phoneApplication?.fullName,
                     savedApplicationYear: record.phoneApplication?.graduationYear,
                     phoneSignup: phoneSignup,
                     canRestartPhoneSetup: mayRestart,
                     intentOutcomeUncertain: record.intentRetryNotBefore != nil && record.binding == nil,
                     intentRetryNotBefore: record.intentRetryNotBefore)
    }

    public func draft() throws -> BConnectedSignupDraft? {
        try persistence.transaction { $0.draft }
    }

    public func saveDraft(_ draft: BConnectedSignupDraft) throws {
        try persistence.transaction { record in
            guard !record.applicationDispatched else { return }
            record.draft = draft
        }
    }

    public func apply(name: String, year: Int, invitation: String) async throws {
        guard !inFlight else { throw BConnectedEnrollmentError.busy }
        inFlight = true; defer { inFlight = false }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try BConnectedEnrollmentWire.metadata(name, limit: 400)
        _ = try BConnectedEnrollmentWire.nonce(invitation)
        guard name.utf16.count <= 100, (1940...Calendar(identifier: .gregorian).component(.year, from: now())).contains(year) else { throw BConnectedEnrollmentError.invalidInput }
        try persistence.transaction { record in
            guard !record.applicationDispatched, record.session == nil else { throw BConnectedEnrollmentError.immutableConflict }
            record.applicationDispatched = true
        }
        let result = try await client.enroll(name: name, year: year, invite: invitation)
        try persistence.transaction { record in
            guard record.session == nil, record.applicationDispatched else { throw BConnectedEnrollmentError.immutableConflict }
            record.session = result
        }
    }

    public func applyPhone(name: String, year: Int, phone: String) async throws {
        guard !inFlight else { throw BConnectedEnrollmentError.busy }
        inFlight = true; defer { inFlight = false }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try BConnectedEnrollmentWire.metadata(name, limit: 400)
        try BConnectedEnrollmentWire.phone(phone)
        guard !name.isEmpty, name.utf16.count <= 100,
              (1940...Calendar(identifier: .gregorian).component(.year, from: now())).contains(year) else {
            throw BConnectedEnrollmentError.invalidInput
        }
        let application = try persistence.transaction { record -> BConnectedCommunityRecord.PhoneApplication in
            guard record.session == nil, record.phoneChallenge == nil else { throw BConnectedEnrollmentError.immutableConflict }
            if let frozen = record.phoneApplication { return frozen }
            // Legacy invitation requests with uncertain outcomes cannot be converted into
            // another identity or session by this new flow.
            guard !record.applicationDispatched else { throw BConnectedEnrollmentError.immutableConflict }
            var random = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else {
                throw BConnectedEnrollmentError.unavailable
            }
            let frozen = BConnectedCommunityRecord.PhoneApplication(
                phone: phone, fullName: name, graduationYear: year,
                nonce: BConnectedEnrollmentWire.base64url(Data(random)),
                createdAtMillis: Int(now().timeIntervalSince1970 * 1000))
            record.phoneApplication = frozen
            record.draft = nil
            record.applicationDispatched = true
            return frozen
        }
        // A retry always transmits the original immutable request, regardless of edited UI.
        let result: BConnectedCommunityRecord.PhoneChallenge
        do { result = try await client.enrollPhone(application) }
        catch BConnectedEnrollmentError.phoneEnrollmentRejected {
            // This exact owned 409 is authoritative and did not mutate the server. Unknown
            // failures retain the frozen nonce so the same request can be retried.
            guard try enrollment.progress() == nil else { throw BConnectedEnrollmentError.immutableConflict }
            try persistence.transaction { record in
                guard record.session == nil, record.binding == nil,
                      record.phoneApplication == application else { throw BConnectedEnrollmentError.immutableConflict }
                record.phoneApplication = nil
                record.applicationDispatched = false
            }
            throw BConnectedEnrollmentError.phoneEnrollmentRejected
        }
        try persistence.transaction { record in
            guard record.session == nil, record.phoneChallenge == nil,
                  record.phoneApplication == application else {
                throw BConnectedEnrollmentError.immutableConflict
            }
            record.phoneChallenge = result
        }
    }

    /// Explicitly discard only an expired, unverified challenge that never
    /// created a member session, binding or native registration attempt.
    public func restartExpiredPhoneSetup() throws {
        guard !inFlight else { throw BConnectedEnrollmentError.busy }
        guard try enrollment.progress() == nil else { throw BConnectedEnrollmentError.immutableConflict }
        try persistence.transaction { record in
            guard let challenge = record.phoneChallenge, record.phoneApplication != nil,
                  record.session == nil, record.phoneSignup?.operationId == nil,
                  record.phoneSignup?.observation?.phoneVerified != true,
                  challenge.expiresAt <= Int(now().timeIntervalSince1970 * 1000),
                  record.binding == nil, record.intentRetryNotBefore == nil else {
                throw BConnectedEnrollmentError.immutableConflict
            }
            record.phoneChallenge = nil
            record.phoneSignup = nil
            record.phoneApplication = nil
            record.applicationDispatched = false
        }
    }

    /// This first network request creates no member and sends no text message.
    /// The explicit send action below is the only SMS-producing client action.
    public func sendPhoneCode(explicitlyResendAfterUncertainOutcome: Bool = false,
                              mayDispatch: () -> Bool = { true }) async throws {
        guard !inFlight else { throw BConnectedEnrollmentError.busy }
        guard let signup else { throw BConnectedEnrollmentError.unavailable }
        inFlight = true; defer { inFlight = false }
        let snapshot = try persistence.transaction { $0 }
        guard let application = snapshot.phoneApplication, let challenge = snapshot.phoneChallenge,
              snapshot.session == nil else { throw BConnectedEnrollmentError.approvalBindingRequired }
        if snapshot.phoneSignup?.operationId == nil {
            let begun: BConnectedPhoneSignupObservation
            do {
                // A lost BEGIN response may already have created the native operation,
                // or even completed SMS verification. Recover before attempting BEGIN.
                begun = try await signup.send(.status, application: application, challenge: challenge, code: nil)
            } catch BConnectedEnrollmentError.rejected(.enrollmentUnavailable, retryAfterSeconds: nil) {
                begun = try await signup.send(.begin, application: application, challenge: challenge, code: nil)
            }
            try persistence.transaction { record in
                guard record.phoneApplication == application, record.phoneChallenge == challenge,
                      record.phoneSignup?.operationId == nil else { throw BConnectedEnrollmentError.immutableConflict }
                record.phoneSignup = .init(operationId: begun.operationId, observation: begun, observedAt: now())
            }
            if begun.phoneVerified {
                try await pollVerifiedPhoneStatus(application: application, challenge: challenge)
                return
            }
        }
        try Task.checkCancellation()
        guard mayDispatch() else { throw CancellationError() }
        try persistence.transaction { record in
            guard record.phoneApplication == application, record.phoneChallenge == challenge,
                  record.phoneSignup?.operationId == challenge.applicationId,
                  record.phoneSignup?.observation?.phoneVerified != true,
                  record.phoneSignup?.observation?.nextSmsSeconds == 0 else {
                throw BConnectedEnrollmentError.immutableConflict
            }
            guard record.phoneSignup?.sendNeedsExplicitDecision != true || explicitlyResendAfterUncertainOutcome else {
                throw BConnectedEnrollmentError.explicitSendRequired
            }
            record.phoneSignup!.sendNeedsExplicitDecision = true
        }
        let sent: BConnectedPhoneSignupObservation
        do { sent = try await signup.send(.sendCode, application: application, challenge: challenge, code: nil) }
        catch BConnectedEnrollmentError.rejected(.rateLimited, let seconds) {
            try saveThrottle(seconds, sending: true)
            throw BConnectedEnrollmentError.rejected(.rateLimited, retryAfterSeconds: seconds)
        }
        try persistence.transaction { record in
            guard record.phoneApplication == application, record.phoneChallenge == challenge,
                  record.phoneSignup?.operationId == sent.operationId else { throw BConnectedEnrollmentError.immutableConflict }
            record.phoneSignup?.observation = sent
            record.phoneSignup?.observedAt = now()
            record.phoneSignup?.sendNeedsExplicitDecision = false
        }
    }

    public func checkPhoneCode(_ code: String) async throws {
        guard !inFlight else { throw BConnectedEnrollmentError.busy }
        guard let signup else { throw BConnectedEnrollmentError.unavailable }
        inFlight = true; defer { inFlight = false }
        let snapshot = try persistence.transaction { $0 }
        guard let application = snapshot.phoneApplication, let challenge = snapshot.phoneChallenge,
              snapshot.phoneSignup?.operationId == challenge.applicationId,
              snapshot.phoneSignup?.observation?.phoneVerified != true,
              snapshot.phoneSignup?.observation?.nextCheckSeconds == 0 else {
            throw BConnectedEnrollmentError.operationRequired
        }
        let checked: BConnectedPhoneSignupObservation
        do { checked = try await signup.send(.checkCode, application: application, challenge: challenge, code: code) }
        catch BConnectedEnrollmentError.rejected(.rateLimited, let seconds) {
            try saveThrottle(seconds, sending: false)
            throw BConnectedEnrollmentError.rejected(.rateLimited, retryAfterSeconds: seconds)
        }
        try persistence.transaction { record in
            guard record.phoneApplication == application, record.phoneChallenge == challenge,
                  record.phoneSignup?.operationId == checked.operationId else { throw BConnectedEnrollmentError.immutableConflict }
            record.phoneSignup?.observation = checked
            record.phoneSignup?.observedAt = now()
        }
        if checked.phoneVerified { try await pollVerifiedPhoneStatus(application: application, challenge: challenge) }
    }

    public func refreshPhoneVerification() async throws {
        guard !inFlight else { throw BConnectedEnrollmentError.busy }
        guard let signup else { throw BConnectedEnrollmentError.unavailable }
        inFlight = true; defer { inFlight = false }
        let snapshot = try persistence.transaction { $0 }
        guard let application = snapshot.phoneApplication, let challenge = snapshot.phoneChallenge,
              snapshot.session == nil else { throw BConnectedEnrollmentError.operationRequired }
        let status: BConnectedPhoneSignupObservation
        do { status = try await signup.send(.status, application: application, challenge: challenge, code: nil) }
        catch BConnectedEnrollmentError.rejected(.enrollmentUnavailable, retryAfterSeconds: nil) where snapshot.phoneSignup?.operationId == nil {
            return // Never BEGIN or send a text as a consequence of a status read.
        }
        try persistence.transaction { record in
            guard record.phoneApplication == application, record.phoneChallenge == challenge,
                  record.phoneSignup?.operationId == nil || record.phoneSignup?.operationId == status.operationId else {
                throw BConnectedEnrollmentError.immutableConflict
            }
            if record.phoneSignup == nil {
                record.phoneSignup = .init(operationId: status.operationId, observation: nil, sendNeedsExplicitDecision: true)
            }
            record.phoneSignup?.operationId = status.operationId
            record.phoneSignup?.observation = status
            record.phoneSignup?.observedAt = now()
            // An uncertain send remains explicit even after a status read. Status does not
            // prove whether an SMS was delivered or grant permission to send another.
        }
        if status.phoneVerified { try await pollVerifiedPhoneStatus(application: application, challenge: challenge) }
    }

    private func saveThrottle(_ seconds: Int?, sending: Bool) throws {
        try persistence.transaction { record in
            guard let observation = record.phoneSignup?.observation else { return }
            record.phoneSignup?.observation = .init(operationId: observation.operationId, phoneVerified: observation.phoneVerified,
                nextSmsSeconds: sending ? seconds : observation.nextSmsSeconds,
                nextCheckSeconds: sending ? observation.nextCheckSeconds : seconds, expiresInSeconds: observation.expiresInSeconds)
            record.phoneSignup?.observedAt = now()
        }
    }

    private func pollVerifiedPhoneStatus(application: BConnectedCommunityRecord.PhoneApplication,
                                         challenge: BConnectedCommunityRecord.PhoneChallenge) async throws {
        let status = try await client.phoneStatus(nonce: application.nonce)
        switch status {
        case .challenge(let current):
            guard current.applicationId == challenge.applicationId else { throw BConnectedEnrollmentError.invalidResponse }
        case .verified(let session):
            guard session.token == application.nonce,
                  session.member.fullName == application.fullName,
                  session.member.graduationYear == application.graduationYear,
                  session.member.status == .pending || session.member.status == .approved else {
                throw BConnectedEnrollmentError.invalidResponse
            }
            try persistence.transaction { record in
                guard record.phoneApplication == application, record.phoneChallenge == challenge,
                      record.phoneSignup?.observation?.phoneVerified == true,
                      record.session == nil else { throw BConnectedEnrollmentError.immutableConflict }
                record.session = session
            }
        }
    }

    public func refreshApproval() async throws {
        guard !inFlight else { throw BConnectedEnrollmentError.busy }
        inFlight = true; defer { inFlight = false }
        let session = try persistence.transaction { record in
            guard let session = record.session else { throw BConnectedEnrollmentError.approvalBindingRequired }; return session
        }
        let member = try await client.member(token: session.token)
        guard member.id == session.member.id else { throw BConnectedEnrollmentError.invalidResponse }
        try persistence.transaction { record in
            guard record.session?.token == session.token else { throw BConnectedEnrollmentError.immutableConflict }
            record.session?.member = member
        }
    }

    /// Generating inputs may fetch APNs; it runs only when no durable key attempt exists.
    /// The original keys/password/metadata commit BEFORE the community intent request.
    public func connectApprovedMembership(preparation: () async throws -> BConnectedEnrollmentPreparation,
                                          explicitlyRetryLostIntent: Bool = false) async throws {
        guard !inFlight else { throw BConnectedEnrollmentError.busy }
        inFlight = true; defer { inFlight = false }
        let current = try persistence.transaction { $0 }
        guard let session = current.session, session.member.status == .approved else { throw BConnectedEnrollmentError.approvalBindingRequired }
        if let binding = current.binding {
            try enrollment.bindApprovedIntent(memberId: binding.memberId, challenge: binding.bindingChallenge)
            return
        }
        if let retry = current.intentRetryNotBefore {
            guard explicitlyRetryLostIntent, now() >= retry else { throw BConnectedEnrollmentError.explicitSendRequired }
        }
        let material: BConnectedEnrollmentIntentMaterial
        if let existing = try enrollment.progress() { material = existing.intent }
        else {
            let prepared = try await preparation()
            if let appliedPhone = current.phoneApplication?.phone, prepared.phone != appliedPhone {
                throw BConnectedEnrollmentError.invalidInput
            }
            material = try enrollment.prepare(prepared)
        }
        try persistence.transaction { record in
            guard record.session?.token == session.token, record.binding == nil else { throw BConnectedEnrollmentError.immutableConflict }
            if let retry = record.intentRetryNotBefore {
                guard explicitlyRetryLostIntent, now() >= retry else { throw BConnectedEnrollmentError.explicitSendRequired }
            }
            // Five minutes is the existing service's maximum intent TTL, not local permission.
            // The server still decides whether a later explicit retry is eligible.
            record.intentRetryNotBefore = now().addingTimeInterval(300)
        }
        let binding = try await client.intent(token: session.token, material: material)
        guard binding.memberId == session.member.id else { throw BConnectedEnrollmentError.invalidResponse }
        try persistence.transaction { record in
            guard record.session?.token == session.token, record.binding == nil else { throw BConnectedEnrollmentError.immutableConflict }
            // Persist the response before cross-store binding so a restart can finish locally.
            record.binding = binding; record.intentRetryNotBefore = nil
        }
        try enrollment.bindApprovedIntent(memberId: binding.memberId, challenge: binding.bindingChallenge)
    }
}
