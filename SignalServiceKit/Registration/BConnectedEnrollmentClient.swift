// Copyright 2026 BConnected contributors. SPDX-License-Identifier: AGPL-3.0-only

public import Foundation

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
