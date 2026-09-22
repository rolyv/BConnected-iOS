// Copyright 2026 BConnected contributors. SPDX-License-Identifier: AGPL-3.0-only
import Foundation

protocol BConnectedOwnedHTTPSending {
    func send(_ request: URLRequest) async throws -> (Data, Int)
}

/// Shared restrictive transport for the separately configured community and enrollment origins.
final class BConnectedOwnedHTTP: BConnectedOwnedHTTPSending {
    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
    private let session: URLSession

    init(protocolClasses: [AnyClass]? = nil) {
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

    func send(_ request: URLRequest) async throws -> (Data, Int) {
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
            return (data, response.statusCode)
        } catch let error as BConnectedEnrollmentError { throw error }
        catch { throw BConnectedEnrollmentError.unavailable }
    }
}
