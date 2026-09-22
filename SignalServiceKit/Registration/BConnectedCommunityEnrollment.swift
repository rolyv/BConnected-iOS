// Copyright 2026 BConnected contributors. SPDX-License-Identifier: AGPL-3.0-only

public import Foundation

public struct BConnectedCommunityMember: Codable, Equatable {
    public enum Status: String, Codable { case pending, approved, rejected, suspended }
    public let id: String
    public let fullName: String
    public let graduationYear: Int
    public let status: Status
}

public struct BConnectedCommunityProgress {
    public let member: BConnectedCommunityMember?
    public let applicationOutcomeUncertain: Bool
    public let intentOutcomeUncertain: Bool
    public let intentRetryNotBefore: Date?
}

struct BConnectedCommunityRecord: Codable, CustomStringConvertible, CustomDebugStringConvertible {
    var description: String { "BConnectedCommunityRecord(redacted)" }
    var debugDescription: String { description }
    struct Session: Codable { let token: String; let expiresAt: Int; var member: BConnectedCommunityMember }
    struct Binding: Codable { let memberId: String; let bindingChallenge: String; let expiresAt: Int }
    var version = 1
    var applicationDispatched = false
    var session: Session?
    var intentRetryNotBefore: Date?
    var binding: Binding?

    func validate() throws {
        guard version == 1 else { throw BConnectedEnrollmentError.persistenceUnavailable }
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
    func member(token: String) async throws -> BConnectedCommunityMember
    func intent(token: String, material: BConnectedEnrollmentIntentMaterial) async throws -> BConnectedCommunityRecord.Binding
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

@MainActor
public final class BConnectedCommunityEnrollmentCoordinator {
    private let persistence: any BConnectedCommunityPersistence
    private let client: any BConnectedCommunitySending
    private let enrollment: BConnectedEnrollmentCoordinator
    private let now: () -> Date
    private var inFlight = false

    init(persistence: any BConnectedCommunityPersistence, client: any BConnectedCommunitySending,
         enrollment: BConnectedEnrollmentCoordinator, now: @escaping () -> Date = Date.init) {
        self.persistence = persistence; self.client = client; self.enrollment = enrollment; self.now = now
    }

    public func progress() throws -> BConnectedCommunityProgress {
        try persistence.transaction { record in
            try record.validate()
            return .init(member: record.session?.member, applicationOutcomeUncertain: record.applicationDispatched && record.session == nil,
                         intentOutcomeUncertain: record.intentRetryNotBefore != nil && record.binding == nil,
                         intentRetryNotBefore: record.intentRetryNotBefore)
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
        else { material = try enrollment.prepare(await preparation()) }
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
