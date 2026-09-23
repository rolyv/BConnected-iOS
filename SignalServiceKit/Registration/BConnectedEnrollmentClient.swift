// Copyright 2026 BConnected contributors. SPDX-License-Identifier: AGPL-3.0-only

public import Foundation
import CryptoKit

public struct BConnectedPublicationConfiguration {
    let origin: URL
    let hash: Data

    /// Only a native-validated public authority commitment may be supplied by app composition.
    init(origin: URL, authorityCommitment: Data) throws {
        _ = try BConnectedEnrollmentEndpoint(origin: origin)
        guard authorityCommitment.count == 32, var components = URLComponents(url: origin, resolvingAgainstBaseURL: false),
              let host = components.host?.lowercased(), !host.isEmpty, host.utf8.count <= 253,
              host.utf8.allSatisfy({ (48...57).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 46 }),
              !host.split(separator: ".", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0.first == "-" || $0.last == "-" || $0.utf8.count > 63 }),
              !["signal.org", "whispersystems.org"].contains(where: { host == $0 || host.hasSuffix("." + $0) }) else {
            throw BConnectedEnrollmentError.invalidInput
        }
        components.host = host; components.path = ""
        if components.port == 443 { components.port = nil }
        guard let canonical = components.url else { throw BConnectedEnrollmentError.invalidInput }
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
              let keys = record.preKeyPublication, keys.batch(identity).state == .dispatched else { throw BConnectedEnrollmentError.immutableConflict }
        var components = URLComponents(url: configuration.origin, resolvingAgainstBaseURL: false)!
        components.path = "/v2/keys"; components.queryItems = [URLQueryItem(name: "identity", value: identity.rawValue)]
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

protocol BConnectedEnrollmentSending {
    func send(_ operation: BConnectedEnrollmentOperation, record: BConnectedEnrollmentRecord, code: String?) async throws -> BConnectedEnrollmentObservation
}

/// Own enrollment REST origin, explicitly configured separately from the messaging socket listener.
public struct BConnectedEnrollmentEndpoint {
    let origin: URL
    public init(origin: URL) throws {
        guard let components = URLComponents(url: origin, resolvingAgainstBaseURL: false),
              components.scheme == "https", let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil, components.query == nil,
              components.fragment == nil, ["", "/"].contains(components.path),
              components.port == nil || (1...65535).contains(components.port!) else { throw BConnectedEnrollmentError.invalidInput }
        self.origin = origin
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
