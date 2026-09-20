// Copyright 2026 BConnected contributors. SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Private GCS reads. The existing backend-configuration guard still controls whether the messenger can build.
enum BConnectedMediaDownload {
    struct Capability: Decodable {
        let url: String
        let expiresAt: TimeInterval
        let contentLength: UInt64
    }

    struct Prepared {
        let session: OWSURLSession
        let request: URLRequest
    }

    static func requiresCapability(cdn: UInt32, path: String) -> Bool {
        (cdn == 0 && path.hasPrefix("profiles/")) || (cdn == 2 && path.hasPrefix("attachments/"))
    }

    static func prepare(cdn: UInt32, path: String, maximumSize: UInt64, range: String? = nil) async throws -> Prepared {
        let key = try validatedKey(cdn: cdn, path: path)
        var request = TSRequest(url: URL(string: "v1/media/download")!, method: "POST", parameters: ["cdn": Int(cdn), "key": key])
        request.auth = .identified(.implicit())
        request.maxResponseSize = 16 * 1024
        let response = try await SSKEnvironment.shared.networkManagerRef.asyncRequest(request)
        guard response.responseStatusCode == 200, let data = response.responseBodyData else { throw response.asError() }
        let capability = try JSONDecoder().decode(Capability.self, from: data)
        guard capability.contentLength <= maximumSize else { throw OWSURLSessionError.responseTooLarge }
        let url = try validatedURL(capability, cdn: cdn, key: key, now: Date())

        let configuration = OWSURLSession.defaultConfigurationWithoutCaching
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 600
        let session = OWSURLSession(securityPolicy: .systemDefault, configuration: configuration)
        session.allowRedirects = false
        return Prepared(session: session, request: try downloadRequest(url: url, range: range))
    }

    static func validatedKey(cdn: UInt32, path: String) throws -> String {
        let key: String
        let encoded: String
        let count: Int
        if cdn == 0, path.range(of: "^profiles/[A-Za-z0-9_-]{22}==$", options: .regularExpression) != nil {
            key = path
            encoded = String(path.dropFirst("profiles/".count))
            count = 16
        } else if cdn == 2, path.range(of: "^attachments/[A-Za-z0-9_-]{20}$", options: .regularExpression) != nil {
            key = String(path.dropFirst("attachments/".count))
            encoded = key
            count = 15
        } else {
            throw OWSAssertionError("Invalid private media key")
        }
        let base64 = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard let data = Data(base64Encoded: base64), data.count == count,
              data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_") == encoded
        else { throw OWSAssertionError("Non-canonical private media key") }
        return key
    }

    static func validatedURL(_ capability: Capability, cdn: UInt32, key: String, now: Date) throws -> URL {
        _ = try validatedKey(cdn: cdn, path: cdn == 2 ? "attachments/\(key)" : key)
        let bucket: String
        switch cdn {
        case 0: bucket = "roly-dev-bconnected-avatars"
        case 2: bucket = "roly-dev-bconnected-attachments"
        default: throw OWSAssertionError("Unsupported private media CDN")
        }
        guard let components = URLComponents(string: capability.url), let url = components.url,
              components.scheme == "https", components.host == "storage.googleapis.com",
              components.port == nil, components.user == nil, components.password == nil, components.fragment == nil,
              components.percentEncodedPath.removingPercentEncoding == "/\(bucket)/\(key)",
              capability.expiresAt > now.timeIntervalSince1970,
              capability.expiresAt <= now.timeIntervalSince1970 + 305
        else { throw OWSAssertionError("Invalid private media capability") }
        var fields = [String: String]()
        for item in components.queryItems ?? [] {
            guard let value = item.value, fields.updateValue(value, forKey: item.name) == nil else {
                throw OWSAssertionError("Invalid private media query")
            }
        }
        guard Set(fields.keys) == ["X-Goog-Algorithm", "X-Goog-Credential", "X-Goog-Date", "X-Goog-Expires", "X-Goog-SignedHeaders", "X-Goog-Signature", "generation"],
              fields["X-Goog-Algorithm"] == "GOOG4-RSA-SHA256", fields["X-Goog-SignedHeaders"] == "host",
              let generationText = fields["generation"], let generation = UInt64(generationText), generation > 0,
              let seconds = fields["X-Goog-Expires"].flatMap(TimeInterval.init), seconds >= 1, seconds <= 300,
              let timestamp = fields["X-Goog-Date"], timestamp.range(of: "^[0-9]{8}T[0-9]{6}Z$", options: .regularExpression) != nil,
              fields["X-Goog-Signature"]?.range(of: "^[0-9a-f]{512,1024}$", options: .regularExpression) != nil,
              fields["X-Goog-Credential"] == "bconnected-signal@roly-dev.iam.gserviceaccount.com/\(timestamp.prefix(8))/auto/storage/goog4_request"
        else { throw OWSAssertionError("Invalid private media signature scope") }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        formatter.isLenient = false
        guard let signedAt = formatter.date(from: timestamp), signedAt <= now.addingTimeInterval(5),
              abs(signedAt.timeIntervalSince1970 + seconds - capability.expiresAt) < 1
        else { throw OWSAssertionError("Invalid private media expiry") }
        return url
    }

    static func downloadRequest(url: URL, range: String?) throws -> URLRequest {
        // Build a new request. Never forward chat authorization, CDN backup credentials, cookies or other headers.
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let range {
            guard range.range(of: "^bytes=[0-9]+-[0-9]*$", options: .regularExpression) != nil else {
                throw OWSAssertionError("Invalid private media range")
            }
            request.setValue(range, forHTTPHeaderField: "Range")
        }
        return request
    }
}
