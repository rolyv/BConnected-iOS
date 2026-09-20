// Copyright 2026 BConnected contributors. SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import XCTest
@testable import SignalServiceKit

final class BConnectedMediaDownloadTest: XCTestCase {
    private let avatar = "profiles/AAAAAAAAAAAAAAAAAAAAAA=="
    private let attachment = "AAAAAAAAAAAAAAAAAAAA"
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func capability(cdn: UInt32 = 0, change: (inout URLComponents) -> Void = { _ in }, expiresAt: TimeInterval? = nil) -> BConnectedMediaDownload.Capability {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let timestamp = formatter.string(from: now)
        var components = URLComponents()
        components.scheme = "https"
        components.host = "storage.googleapis.com"
        components.path = cdn == 0 ? "/roly-dev-bconnected-avatars/\(avatar)" : "/roly-dev-bconnected-attachments/\(attachment)"
        components.queryItems = [
            URLQueryItem(name: "X-Goog-Algorithm", value: "GOOG4-RSA-SHA256"),
            URLQueryItem(name: "X-Goog-Credential", value: "bconnected-signal@roly-dev.iam.gserviceaccount.com/\(timestamp.prefix(8))/auto/storage/goog4_request"),
            URLQueryItem(name: "X-Goog-Date", value: timestamp),
            URLQueryItem(name: "X-Goog-Expires", value: "300"),
            URLQueryItem(name: "X-Goog-SignedHeaders", value: "host"),
            URLQueryItem(name: "X-Goog-Signature", value: String(repeating: "0", count: 512)),
            URLQueryItem(name: "generation", value: "42"),
        ]
        change(&components)
        return .init(url: components.url!.absoluteString, expiresAt: expiresAt ?? now.timeIntervalSince1970 + 300, contentLength: 1024)
    }

    func testCanonicalKeysAndAttachmentRoutingPrefix() throws {
        XCTAssertEqual(try BConnectedMediaDownload.validatedKey(cdn: 0, path: avatar), avatar)
        XCTAssertEqual(try BConnectedMediaDownload.validatedKey(cdn: 2, path: "attachments/\(attachment)"), attachment)
        XCTAssertTrue(BConnectedMediaDownload.requiresCapability(cdn: 0, path: avatar))
        XCTAssertTrue(BConnectedMediaDownload.requiresCapability(cdn: 2, path: "attachments/\(attachment)"))
        XCTAssertFalse(BConnectedMediaDownload.requiresCapability(cdn: 3, path: "backup/opaque"))
    }

    func testRejectsUnsafeAndNonCanonicalKeys() {
        for key in ["profiles/../secret", "https://evil.example/object", "profiles/%2fsecret", "profiles/AAAAAAAAAAAAAAAAAAAAAB==", avatar + "\n"] {
            XCTAssertThrowsError(try BConnectedMediaDownload.validatedKey(cdn: 0, path: key))
        }
        XCTAssertThrowsError(try BConnectedMediaDownload.validatedKey(cdn: 2, path: attachment))
        XCTAssertThrowsError(try BConnectedMediaDownload.validatedKey(cdn: 0, path: "attachments/\(attachment)"))
        XCTAssertThrowsError(try BConnectedMediaDownload.validatedKey(cdn: 3, path: avatar))
    }

    func testAcceptsGenerationPinnedGoogleURLs() throws {
        let avatarURL = try BConnectedMediaDownload.validatedURL(capability(), cdn: 0, key: avatar, now: now)
        XCTAssertEqual(avatarURL.host, "storage.googleapis.com")
        let attachmentURL = try BConnectedMediaDownload.validatedURL(capability(cdn: 2), cdn: 2, key: attachment, now: now)
        XCTAssertEqual(attachmentURL.path, "/roly-dev-bconnected-attachments/\(attachment)")
    }

    func testRejectsUntrustedHostsAndPaths() {
        let changes: [(inout URLComponents) -> Void] = [
            { $0.host = "evil.example" }, { $0.scheme = "http" }, { $0.port = 443 },
            { $0.user = "account" }, { $0.fragment = "fragment" },
            { $0.path = "/other-bucket/\(self.avatar)" },
            { $0.path = "/roly-dev-bconnected-avatars/profiles/../other" },
        ]
        for change in changes {
            XCTAssertThrowsError(try BConnectedMediaDownload.validatedURL(capability(change: change), cdn: 0, key: avatar, now: now))
        }
    }

    func testRejectsExpiredOrInconsistentLifetime() {
        XCTAssertThrowsError(try BConnectedMediaDownload.validatedURL(capability(), cdn: 0, key: avatar, now: now.addingTimeInterval(300)))
        XCTAssertThrowsError(try BConnectedMediaDownload.validatedURL(capability(expiresAt: now.timeIntervalSince1970 + 301), cdn: 0, key: avatar, now: now))
        XCTAssertThrowsError(try BConnectedMediaDownload.validatedURL(capability(), cdn: 0, key: avatar, now: now.addingTimeInterval(-6)))
        let longLived = capability(change: { components in
            components.queryItems = components.queryItems!.map { $0.name == "X-Goog-Expires" ? URLQueryItem(name: $0.name, value: "301") : $0 }
        }, expiresAt: now.timeIntervalSince1970 + 301)
        XCTAssertThrowsError(try BConnectedMediaDownload.validatedURL(longLived, cdn: 0, key: avatar, now: now))
    }

    func testRejectsChangedSignatureScopeAndDuplicateQuery() {
        for (field, value) in [
            ("generation", "0"), ("generation", "-1"), ("X-Goog-Credential", "another-signer"),
            ("X-Goog-SignedHeaders", "authorization;host"), ("X-Goog-Algorithm", "AWS4-HMAC-SHA256"),
            ("X-Goog-Signature", "invalid"), ("X-Goog-Date", "20261399T999999Z"),
        ] {
            let altered = capability(change: { components in
                components.queryItems = components.queryItems!.map { $0.name == field ? URLQueryItem(name: field, value: value) : $0 }
            })
            XCTAssertThrowsError(try BConnectedMediaDownload.validatedURL(altered, cdn: 0, key: avatar, now: now))
        }
        let duplicate = capability(change: { $0.queryItems!.append(URLQueryItem(name: "generation", value: "43")) })
        XCTAssertThrowsError(try BConnectedMediaDownload.validatedURL(duplicate, cdn: 0, key: avatar, now: now))
        let extra = capability(change: { $0.queryItems!.append(URLQueryItem(name: "redirect", value: "https://evil.example")) })
        XCTAssertThrowsError(try BConnectedMediaDownload.validatedURL(extra, cdn: 0, key: avatar, now: now))
    }

    func testBuildsFreshGetWithoutCredentialsOrCookies() throws {
        let url = try BConnectedMediaDownload.validatedURL(capability(), cdn: 0, key: avatar, now: now)
        let request = try BConnectedMediaDownload.downloadRequest(url: url, range: "bytes=0-1023")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.allHTTPHeaderFields, ["Accept-Encoding": "identity", "Range": "bytes=0-1023"])
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertNil(request.httpBody)
    }

    func testRejectsInjectedRangeHeader() throws {
        let url = try BConnectedMediaDownload.validatedURL(capability(), cdn: 0, key: avatar, now: now)
        for range in ["bytes=0-1\r\nAuthorization: secret", "bytes=-1", "bytes=0-1,4-5"] {
            XCTAssertThrowsError(try BConnectedMediaDownload.downloadRequest(url: url, range: range))
        }
    }
}
