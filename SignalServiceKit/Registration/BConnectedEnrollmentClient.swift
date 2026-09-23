// Copyright 2026 BConnected contributors. SPDX-License-Identifier: AGPL-3.0-only

public import Foundation
import CryptoKit

/// Shared strict origin validation for BConnected clients that carry credentials.
/// Hosts remain ordinary DNS names; IP literals and ambiguous numeric address forms are rejected.
enum BConnectedOwnedOrigin {
    static func canonicalize(_ origin: URL) throws -> URL {
        guard var components = URLComponents(url: origin, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/",
              components.port == nil || components.port == 443,
              let encodedHost = components.percentEncodedHost, !encodedHost.contains("%"),
              let host = components.host, !host.isEmpty,
              host.utf8.count <= 253,
              host.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 46 }) else {
            throw BConnectedEnrollmentError.invalidInput
        }
        let lowerHost = host.lowercased()
        let labels = lowerHost.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty,
              labels.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 63 && $0.first != "-" && $0.last != "-" && !$0.hasPrefix("xn--") }),
              // Numeric-only and hexadecimal address forms can be interpreted as IP literals by URL stacks.
              !labels.allSatisfy({ label in
                  label.utf8.allSatisfy({ (48...57).contains($0) }) ||
                  (label.hasPrefix("0x") && label.dropFirst(2).utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }))
              }),
              !["signal.org", "whispersystems.org"].contains(where: { lowerHost == $0 || lowerHost.hasSuffix("." + $0) }) else {
            throw BConnectedEnrollmentError.invalidInput
        }
        components.scheme = "https"
        components.host = lowerHost
        components.path = ""
        if components.port == 443 { components.port = nil }
        guard let canonical = components.url, canonical.absoluteString.utf8.allSatisfy({ $0 < 128 }) else {
            throw BConnectedEnrollmentError.invalidInput
        }
        return canonical
    }
}

public struct BConnectedPublicationConfiguration {
    let origin: URL
    let hash: Data

    /// Only a native-validated public authority commitment may be supplied by app composition.
    init(origin: URL, authorityCommitment: Data) throws {
        let canonical = try BConnectedOwnedOrigin.canonicalize(origin)
        guard authorityCommitment.count == 32 else { throw BConnectedEnrollmentError.invalidInput }
        self.origin = canonical
        self.hash = Data(SHA256.hash(data: Data(("BConnected pending publication v1\0" + canonical.absoluteString + "\0").utf8) + authorityCommitment))
    }
}

enum BConnectedPublicationStep: Equatable { case attributes, profile }
protocol BConnectedPublicationSending {
    func send(_ step: BConnectedPublicationStep, record: BConnectedEnrollmentRecord, configuration: BConnectedPublicationConfiguration) async throws
}

final class BConnectedPublicationClient: BConnectedPublicationSending {
    private let http: any BConnectedOwnedHTTPSending
    init(http: any BConnectedOwnedHTTPSending = BConnectedOwnedHTTP(responseMode: .emptyPublication)) { self.http = http }

    func request(_ step: BConnectedPublicationStep, record: BConnectedEnrollmentRecord, configuration: BConnectedPublicationConfiguration) throws -> URLRequest {
        try record.validate()
        guard let account = record.installedAccount, account.deviceId == 1,
              let publication = record.publication, publication.configurationHash == configuration.hash,
              publication.state(for: step) == .dispatched else { throw BConnectedEnrollmentError.immutableConflict }
        var components = URLComponents(url: configuration.origin, resolvingAgainstBaseURL: false)!
        components.path = step == .attributes ? "/v1/accounts/attributes/" : "/v1/profile"
        var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "PUT"
        request.httpBody = step == .attributes ? publication.accountAttributes : publication.encryptedProfile
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("Basic " + Data((account.aci.lowercased() + ":" + record.password).utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        request.setValue(record.originalUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(record.originalSignalAgent, forHTTPHeaderField: "X-Signal-Agent")
        return request
    }

    func send(_ step: BConnectedPublicationStep, record: BConnectedEnrollmentRecord, configuration: BConnectedPublicationConfiguration) async throws {
        let (data, status) = try await http.send(request(step, record: record, configuration: configuration))
        guard status == (step == .attributes ? 204 : 200), data.isEmpty else { throw BConnectedEnrollmentError.invalidResponse }
    }
}

enum BConnectedPreKeyIdentity: String { case aci, pni }
protocol BConnectedPreKeySending {
    func send(_ identity: BConnectedPreKeyIdentity, record: BConnectedEnrollmentRecord, configuration: BConnectedPublicationConfiguration) async throws
}

final class BConnectedPreKeyClient: BConnectedPreKeySending {
    private let http: any BConnectedOwnedHTTPSending
    init(http: any BConnectedOwnedHTTPSending = BConnectedOwnedHTTP(responseMode: .emptyPublication)) { self.http = http }

    func request(_ identity: BConnectedPreKeyIdentity, record: BConnectedEnrollmentRecord, configuration: BConnectedPublicationConfiguration) throws -> URLRequest {
        try record.validate()
        guard let account = record.installedAccount, account.deviceId == 1,
              record.publication?.configurationHash == configuration.hash,
              let keys = record.preKeyPublication, keys.version == 2, let route = keys.route,
              route.origin == configuration.origin.absoluteString, route.configurationHash == configuration.hash,
              keys.batch(identity).state == .dispatched else { throw BConnectedEnrollmentError.immutableConflict }
        var components = URLComponents(url: configuration.origin, resolvingAgainstBaseURL: false)!
        components.path = route.pathPrefix + route.operationId(identity)
        components.queryItems = [URLQueryItem(name: "identity", value: identity.rawValue)]
        var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "PUT"; request.httpBody = keys.batch(identity).request
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("Basic " + Data((account.aci.lowercased() + ":" + record.password).utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        request.setValue(record.originalUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(record.originalSignalAgent, forHTTPHeaderField: "X-Signal-Agent")
        return request
    }

    func send(_ identity: BConnectedPreKeyIdentity, record: BConnectedEnrollmentRecord, configuration: BConnectedPublicationConfiguration) async throws {
        let (data, status) = try await http.send(request(identity, record: record, configuration: configuration))
        guard status == 204, data.isEmpty else { throw BConnectedEnrollmentError.invalidResponse }
    }
}

enum BConnectedAccountAcceptanceStep: CaseIterable { case identity, profile }

protocol BConnectedAccountAcceptanceReading {
    func read(_ step: BConnectedAccountAcceptanceStep, record: BConnectedEnrollmentRecord,
              configuration: BConnectedPublicationConfiguration) async throws
}

/// Reads back the first account and encrypted profile from the same frozen owned origin.
/// Successful reads are an observation only: no credential, lifecycle or readiness capability.
final class BConnectedAccountAcceptanceClient: BConnectedAccountAcceptanceReading {
    private let http: any BConnectedOwnedHTTPSending
    init(http: any BConnectedOwnedHTTPSending = BConnectedOwnedHTTP(responseMode: .accountJSON)) { self.http = http }

    func request(_ step: BConnectedAccountAcceptanceStep, record: BConnectedEnrollmentRecord,
                 configuration: BConnectedPublicationConfiguration) throws -> URLRequest {
        try record.validateAccountAcceptance(configuration: configuration)
        let account = record.installedAccount!
        let profile = try BConnectedEnrollmentWire.object(record.publication!.encryptedProfile)
        var components = URLComponents(url: configuration.origin, resolvingAgainstBaseURL: false)!
        components.path = step == .identity ? "/v1/accounts/whoami" : "/v1/profile/\(account.aci)/\(try BConnectedEnrollmentWire.text(profile["version"]))"
        var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("Basic " + Data((account.aci + ":" + record.password).utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        request.setValue(record.originalUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(record.originalSignalAgent, forHTTPHeaderField: "X-Signal-Agent")
        return request
    }

    func read(_ step: BConnectedAccountAcceptanceStep, record: BConnectedEnrollmentRecord,
              configuration: BConnectedPublicationConfiguration) async throws {
        let (data, status) = try await http.send(request(step, record: record, configuration: configuration))
        try Task.checkCancellation()
        let publication = record.publication!
        let registration = try BConnectedEnrollmentWire.object(record.registrationRequest)
        try Self.validateResponse(data, status: status, step: step, account: record.installedAccount!,
            attributes: publication.accountAttributes, profile: publication.encryptedProfile,
            identityKey: BConnectedEnrollmentWire.base64(registration["aciIdentityKey"]))
    }

    /// Public wire inputs only, also used by the Java serializer interoperability fixture.
    /// The caller's durable/native checks remain necessary; this parser creates no authorization.
    static func validateResponse(_ data: Data, status: Int, step: BConnectedAccountAcceptanceStep,
        account: BConnectedEnrollmentObservation.Account, attributes: Data, profile: Data, identityKey: Data
    ) throws {
        do {
            guard status == 200 else { throw BConnectedEnrollmentError.invalidResponse }
            let response = try BConnectedEnrollmentWire.object(data)
            let attributes = try BConnectedEnrollmentWire.object(attributes)
            guard let capabilities = attributes["capabilities"] as? [String: Any] else { throw BConnectedEnrollmentError.invalidResponse }
            func absent(_ field: String) -> Bool { response[field] == nil || response[field] is NSNull }
            guard try BConnectedEnrollmentWire.uuid(response["uuid"]) == account.aci else { throw BConnectedEnrollmentError.invalidResponse }
            switch step {
            case .identity:
                _ = try BConnectedEnrollmentWire.fields(response, required: ["uuid", "number", "pni", "storageCapable", "entitlements"],
                    optional: ["usernameHash", "usernameLinkHandle", "authCredentialSalt"])
                guard try BConnectedEnrollmentWire.text(response["number"]) == account.number,
                      try BConnectedEnrollmentWire.uuid(response["pni"]) == account.pni,
                      try BConnectedEnrollmentWire.boolean(response["storageCapable"]) == (capabilities["storage"] as? Bool ?? false),
                      response["entitlements"] is [String: Any], absent("usernameHash"), absent("usernameLinkHandle"), absent("authCredentialSalt") else {
                    throw BConnectedEnrollmentError.invalidResponse
                }
                // Entitlements are deliberately not consumed or converted into any local grant.
            case .profile:
                _ = try BConnectedEnrollmentWire.fields(response,
                    required: ["uuid", "identityKey", "unidentifiedAccess", "unrestrictedUnidentifiedAccess", "capabilities", "badges", "phoneNumberSharing"],
                    optional: ["name", "about", "aboutEmoji", "avatar", "paymentAddress"])
                let uak = try BConnectedEnrollmentWire.base64(attributes["unidentifiedAccessKey"])
                let checksum = Data(HMAC<SHA256>.authenticationCode(for: Data(repeating: 0, count: 32), using: SymmetricKey(data: uak)))
                guard try BConnectedEnrollmentWire.base64(response["identityKey"]) == identityKey,
                      try BConnectedEnrollmentWire.base64(response["unidentifiedAccess"]) == checksum,
                      try BConnectedEnrollmentWire.boolean(response["unrestrictedUnidentifiedAccess"]) == false,
                      (response["badges"] as? [Any])?.isEmpty == true, absent("avatar"), absent("paymentAddress") else {
                    throw BConnectedEnrollmentError.invalidResponse
                }
                let visible: Set<String> = ["attachmentBackfill", "spqr", "profiles_v2", "usernameChangeSyncMessage"]
                let received = try BConnectedEnrollmentWire.fields(response["capabilities"], required: visible)
                for name in visible {
                    guard try BConnectedEnrollmentWire.boolean(received[name]) == (capabilities[name] as? Bool ?? false) else {
                        throw BConnectedEnrollmentError.invalidResponse
                    }
                }
                let profile = try BConnectedEnrollmentWire.object(profile)
                for name in ["name", "about", "aboutEmoji", "phoneNumberSharing"] {
                    if let expected = profile[name] {
                        guard try BConnectedEnrollmentWire.base64(response[name]) == BConnectedEnrollmentWire.base64(expected) else {
                            throw BConnectedEnrollmentError.invalidResponse
                        }
                    } else if !absent(name) { throw BConnectedEnrollmentError.invalidResponse }
                }
            }
        } catch { throw BConnectedEnrollmentError.invalidResponse }
    }
}

protocol BConnectedEnrollmentSending {
    func send(_ operation: BConnectedEnrollmentOperation, record: BConnectedEnrollmentRecord, code: String?) async throws -> BConnectedEnrollmentObservation
}

/// Own enrollment REST origin, explicitly configured separately from the messaging socket listener.
public struct BConnectedEnrollmentEndpoint {
    let origin: URL
    public init(origin: URL) throws {
        self.origin = try BConnectedOwnedOrigin.canonicalize(origin)
    }
}

final class BConnectedEnrollmentClient: BConnectedEnrollmentSending {
    private let endpoint: BConnectedEnrollmentEndpoint
    private let http: any BConnectedOwnedHTTPSending
    init(endpoint: BConnectedEnrollmentEndpoint, protocolClasses: [AnyClass]? = nil) {
        self.endpoint = endpoint
        self.http = BConnectedOwnedHTTP(protocolClasses: protocolClasses)
    }

    func request(_ operation: BConnectedEnrollmentOperation, record: BConnectedEnrollmentRecord, code: String?) throws -> URLRequest {
        try record.validate()
        var path = "/v1/bconnected/enrollment/"
        if operation == .begin { path += "begin" }
        else {
            guard let id = record.operationId else { throw BConnectedEnrollmentError.operationRequired }
            path += try BConnectedEnrollmentWire.uuid(id) + "/" + operation.rawValue
        }
        var components = URLComponents(url: endpoint.origin, resolvingAgainstBaseURL: false)!
        components.path = path
        guard let url = components.url else { throw BConnectedEnrollmentError.invalidInput }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.httpBody = try record.body(for: operation, code: code)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("Basic " + Data((record.phone + ":" + record.password).utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        request.setValue(record.originalUserAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    func send(_ operation: BConnectedEnrollmentOperation, record: BConnectedEnrollmentRecord, code: String?) async throws -> BConnectedEnrollmentObservation {
        let request = try request(operation, record: record, code: code)
        let (data, status) = try await http.send(request)
        return try BConnectedEnrollmentWire.response(data, status: status, operation: operation,
                                                     expectedOperation: record.operationId, expectedPhone: record.phone)
    }
}
