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
    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
    private let endpoint: BConnectedEnrollmentEndpoint
    private let session: URLSession

    init(endpoint: BConnectedEnrollmentEndpoint, protocolClasses: [AnyClass]? = nil) {
        self.endpoint = endpoint
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = protocolClasses
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }

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
        do {
            // No retry loop. A request may have reached the provider even if no response arrives.
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let response = response as? HTTPURLResponse, response.url == request.url,
                  response.value(forHTTPHeaderField: "Content-Type")?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() == "application/json",
                  response.value(forHTTPHeaderField: "Cache-Control")?.lowercased().split(separator: ",").contains(where: { $0.trimmingCharacters(in: .whitespaces) == "no-store" }) == true,
                  response.expectedContentLength <= BConnectedEnrollmentWire.maximumBytes else { throw BConnectedEnrollmentError.invalidResponse }
            var data = Data()
            for try await byte in bytes {
                guard data.count < BConnectedEnrollmentWire.maximumBytes else { throw BConnectedEnrollmentError.invalidResponse }
                data.append(byte)
            }
            return try BConnectedEnrollmentWire.response(data, status: response.statusCode, operation: operation,
                                                         expectedOperation: record.operationId, expectedPhone: record.phone)
        } catch let error as BConnectedEnrollmentError { throw error }
        catch { throw BConnectedEnrollmentError.unavailable }
    }
}
