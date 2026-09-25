// Copyright 2026 BConnected contributors. SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Approved-directory metadata, not a decrypted Signal profile or a send authorization.
public struct BConnectedDirectoryMember: Codable, Equatable, Sendable {
    public let aci: String
    public let deviceId: Int
    public let fullName: String
    public let graduationYear: Int
}

public struct BConnectedDirectoryPage: Equatable, Sendable {
    public let members: [BConnectedDirectoryMember]
    public let nextOffset: Int?
}

public final class BConnectedDirectoryClient {
    private let http: any BConnectedOwnedHTTPSending
    public convenience init() { self.init(http: BConnectedOwnedHTTP(responseMode: .enrollmentJSON)) }
    init(http: any BConnectedOwnedHTTPSending) { self.http = http }

    public func search(query: String, offset: Int, credentials: BConnectedPrimaryRecipientCredentials,
                       configuration: BConnectedPublicationConfiguration) async throws -> BConnectedDirectoryPage {
        let request = try searchRequest(query: query, offset: offset, credentials: credentials, configuration: configuration)
        let (data, status) = try await http.send(request)
        try Task.checkCancellation()
        return try Self.validatePage(data, status: status, offset: offset)
    }

    public func resolve(aci: String, credentials: BConnectedPrimaryRecipientCredentials,
                        configuration: BConnectedPublicationConfiguration) async throws -> BConnectedDirectoryMember {
        _ = try BConnectedEnrollmentWire.uuid(aci)
        let request = try request(action: "resolve", body: ["aci": aci], credentials: credentials, configuration: configuration)
        let (data, status) = try await http.send(request)
        try Task.checkCancellation()
        guard status == 200 else { throw BConnectedEnrollmentError.unavailable }
        do {
            let member = try Self.member(BConnectedEnrollmentWire.object(data))
            guard member.aci == aci else { throw BConnectedEnrollmentError.invalidResponse }
            return member
        } catch { throw BConnectedEnrollmentError.invalidResponse }
    }

    func searchRequest(query: String, offset: Int, credentials: BConnectedPrimaryRecipientCredentials,
                       configuration: BConnectedPublicationConfiguration) throws -> URLRequest {
        guard query.unicodeScalars.count <= 100, !query.unicodeScalars.contains(where: { $0.value < 32 || (127...159).contains($0.value) }),
              (0...10_000).contains(offset) else { throw BConnectedEnrollmentError.invalidInput }
        return try request(action: "search", body: ["query": query, "offset": offset], credentials: credentials, configuration: configuration)
    }

    private func request(action: String, body: [String: Any], credentials: BConnectedPrimaryRecipientCredentials,
                         configuration: BConnectedPublicationConfiguration) throws -> URLRequest {
        var url = URLComponents(url: configuration.origin, resolvingAgainstBaseURL: false)!
        url.path = "/v1/bconnected/directory/" + action
        var request = URLRequest(url: url.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.httpBody = try BConnectedEnrollmentWire.encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        credentials.authenticate(&request)
        return request
    }

    static func validatePage(_ data: Data, status: Int, offset: Int) throws -> BConnectedDirectoryPage {
        guard status == 200 else { throw BConnectedEnrollmentError.unavailable }
        do {
            let root = try BConnectedEnrollmentWire.fields(BConnectedEnrollmentWire.object(data), required: ["members", "nextOffset"])
            guard let values = root["members"] as? [Any], values.count <= 20 else { throw BConnectedEnrollmentError.invalidResponse }
            let members = try values.map(member)
            guard Set(members.map(\.aci)).count == members.count else { throw BConnectedEnrollmentError.invalidResponse }
            let next: Int?
            if root["nextOffset"] is NSNull { next = nil }
            else {
                let value = try BConnectedEnrollmentWire.integer(root["nextOffset"])
                // Native admission filtering can omit an entire candidate page.
                guard (0...10_000).contains(offset), value == offset + 20, value <= 10_000 else { throw BConnectedEnrollmentError.invalidResponse }
                next = value
            }
            return BConnectedDirectoryPage(members: members, nextOffset: next)
        } catch { throw BConnectedEnrollmentError.invalidResponse }
    }

    static func member(_ value: Any) throws -> BConnectedDirectoryMember {
        let fields = try BConnectedEnrollmentWire.fields(value, required: ["aci", "deviceId", "fullName", "graduationYear"])
        let aci = try BConnectedEnrollmentWire.uuid(fields["aci"])
        let name = try BConnectedEnrollmentWire.text(fields["fullName"])
        let year = try BConnectedEnrollmentWire.integer(fields["graduationYear"])
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let currentYear = calendar.component(.year, from: Date())
        guard try BConnectedEnrollmentWire.integer(fields["deviceId"]) == 1,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf16.count <= 100,
              !name.unicodeScalars.contains(where: { $0.value < 32 || (127...159).contains($0.value) }),
              (1940...currentYear).contains(year) else { throw BConnectedEnrollmentError.invalidResponse }
        return BConnectedDirectoryMember(aci: aci, deviceId: 1, fullName: name, graduationYear: year)
    }
}

/// Transient account snapshot. Neither these credentials nor a community token enter the cache.
public struct BConnectedDirectoryAccount: Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let aci: String
    public let credentials: BConnectedPrimaryRecipientCredentials
    private let password: String

    init(aci: String, password: String, userAgent: String = OWSURLSession.userAgentHeaderValueSignalIos) throws {
        self.aci = aci
        self.password = password
        self.credentials = try BConnectedPrimaryRecipientCredentials(aci: aci, password: password, deviceId: 1,
            userAgent: userAgent, signalAgent: "OWI")
    }

    public static func current(tx: DBReadTransaction) -> Self? {
        let manager = DependenciesBridge.shared.tsAccountManager
        guard (try? manager.registeredState(tx: tx)) != nil,
              manager.storedDeviceId(tx: tx).ifValid == .primary,
              let aci = manager.localIdentifiers(tx: tx)?.aci.serviceIdString,
              let password = manager.storedServerAuthToken(tx: tx) else { return nil }
        return try? Self(aci: aci, password: password)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.aci == rhs.aci && lhs.password == rhs.password }
    public var description: String { "BConnectedDirectoryAccount(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
