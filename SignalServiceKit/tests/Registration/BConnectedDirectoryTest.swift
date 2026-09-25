// Copyright 2026 BConnected contributors. SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import GRDB
import XCTest
@testable import SignalServiceKit

final class BConnectedDirectoryTest: XCTestCase, @unchecked Sendable {
    private let owner = "11111111-1111-4111-8111-111111111111"
    private let target = "22222222-2222-4222-8222-222222222222"
    private let otherOwner = "33333333-3333-4333-8333-333333333333"

    private func account(_ aci: String? = nil, passwordByte: UInt8 = 9) throws -> BConnectedDirectoryAccount {
        try BConnectedDirectoryAccount(aci: aci ?? owner, password: Data(repeating: passwordByte, count: 32).base64EncodedString(), userAgent: "DirectoryTests/1")
    }

    private func configuration() throws -> BConnectedPublicationConfiguration {
        try BConnectedPublicationConfiguration(origin: URL(string: "https://owned.example.invalid")!, authorityCommitment: Data(repeating: 7, count: 32))
    }

    private func member(_ aci: String? = nil, name: String = "José María 王", year: Int = 2001) -> BConnectedDirectoryMember {
        BConnectedDirectoryMember(aci: aci ?? target, deviceId: 1, fullName: name, graduationYear: year)
    }

    private func fields(_ member: BConnectedDirectoryMember) -> [String: Any] {
        ["aci": member.aci, "deviceId": member.deviceId, "fullName": member.fullName, "graduationYear": member.graduationYear]
    }

    func testSearchUsesOwnedPOSTWithCurrentPrimaryAuthAndNoQueryMetadata() async throws {
        let http = DirectoryHTTP(data: try BConnectedEnrollmentWire.encode(["members": [fields(member())], "nextOffset": NSNull()]))
        let result = try await BConnectedDirectoryClient(http: http).search(query: "José 2001", offset: 0,
            credentials: account().credentials, configuration: configuration())
        XCTAssertEqual(result.members, [member()])
        XCTAssertNil(result.nextOffset)
        let request = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/v1/bconnected/directory/search")
        XCTAssertEqual(request.url?.host, "owned.example.invalid")
        XCTAssertNil(request.url?.query)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic " + Data((owner + ":" + Data(repeating: 9, count: 32).base64EncodedString()).utf8).base64EncodedString())
        let body = try BConnectedEnrollmentWire.object(XCTUnwrap(request.httpBody))
        XCTAssertEqual(Set(body.keys), ["query", "offset"])
        XCTAssertEqual(body["query"] as? String, "José 2001")
        XCTAssertEqual(body["offset"] as? Int, 0)
    }

    func testInvalidQueryOrOffsetNeverDispatches() async throws {
        let http = DirectoryHTTP(data: Data())
        let client = BConnectedDirectoryClient(http: http)
        for (query, offset) in [(String(repeating: "😀", count: 101), 0), ("name\n", 0), ("", -1), ("", 10_001)] {
            do {
                _ = try await client.search(query: query, offset: offset, credentials: account().credentials, configuration: configuration())
                XCTFail("Accepted invalid search")
            } catch { XCTAssertEqual(error as? BConnectedEnrollmentError, .invalidInput) }
        }
        XCTAssertTrue(http.requests.isEmpty)
        let accepted = try client.searchRequest(query: String(repeating: "😀", count: 100), offset: 10_000,
            credentials: account().credentials, configuration: configuration())
        XCTAssertNotNil(accepted.httpBody)
    }

    func testEmptyFilteredPageCanAdvanceAndDuplicateNamesRemainDistinct() throws {
        let empty = try BConnectedEnrollmentWire.encode(["members": [], "nextOffset": 20])
        XCTAssertEqual(try BConnectedDirectoryClient.validatePage(empty, status: 200, offset: 0).nextOffset, 20)
        let last = try BConnectedEnrollmentWire.encode(["members": [], "nextOffset": 10_000])
        XCTAssertEqual(try BConnectedDirectoryClient.validatePage(last, status: 200, offset: 9_980).nextOffset, 10_000)
        XCTAssertThrowsError(try BConnectedDirectoryClient.validatePage(last, status: 200, offset: 9_981))
        let overflow = try BConnectedEnrollmentWire.encode(["members": [], "nextOffset": 10_020])
        XCTAssertThrowsError(try BConnectedDirectoryClient.validatePage(overflow, status: 200, offset: 10_000))
        let second = member(otherOwner, year: 2005)
        let page = try BConnectedEnrollmentWire.encode(["members": [fields(member()), fields(second)], "nextOffset": NSNull()])
        XCTAssertEqual(try BConnectedDirectoryClient.validatePage(page, status: 200, offset: 0).members, [member(), second])
    }

    func testStrictPageRejectsExtraPrivateFieldsDuplicateIdentitiesAndInvalidCursors() throws {
        var phoneField = fields(member())
        phoneField["phoneNumber"] = "+12025550123"
        let values: [[String: Any]] = [
            ["members": [phoneField], "nextOffset": NSNull()],
            ["members": [fields(member()), fields(member())], "nextOffset": NSNull()],
            ["members": [], "nextOffset": 0],
            ["members": [], "nextOffset": 19],
            ["members": [], "nextOffset": 21],
            ["members": [], "nextOffset": true],
            ["members": [], "nextOffset": NSNull(), "memberId": owner],
            ["members": Array(repeating: fields(member()), count: 21), "nextOffset": NSNull()],
        ]
        for value in values {
            XCTAssertThrowsError(try BConnectedDirectoryClient.validatePage(BConnectedEnrollmentWire.encode(value), status: 200, offset: 0))
        }
        let duplicateJSON = Data("{\"members\":[],\"members\":[],\"nextOffset\":null}".utf8)
        XCTAssertThrowsError(try BConnectedDirectoryClient.validatePage(duplicateJSON, status: 200, offset: 0))
    }

    func testMemberValidationPreservesWholeUnicodeNameAndRejectsUnsupportedMetadata() throws {
        XCTAssertEqual(try BConnectedDirectoryClient.member(fields(member())), member())
        for (key, value) in [("aci", target.uppercased() as Any), ("deviceId", 2), ("fullName", "   "),
                             ("fullName", String(repeating: "😀", count: 51)), ("graduationYear", 1939), ("graduationYear", true)] {
            // The numeric-only fixture UUID has no uppercase letters; use a separate noncanonical UUID.
            var invalid = fields(member())
            invalid[key] = key == "aci" ? "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA" : value
            XCTAssertThrowsError(try BConnectedDirectoryClient.member(invalid))
        }
    }

    func testResolveRequiresMatchingACIAndReturnsOnlyExactMemberSchema() async throws {
        let http = DirectoryHTTP(data: try BConnectedEnrollmentWire.encode(fields(member())))
        let client = BConnectedDirectoryClient(http: http)
        let resolved = try await client.resolve(aci: target, credentials: account().credentials, configuration: configuration())
        XCTAssertEqual(resolved, member())
        XCTAssertEqual(http.requests.first?.url?.path, "/v1/bconnected/directory/resolve")
        http.data = try BConnectedEnrollmentWire.encode(fields(member(otherOwner)))
        do {
            _ = try await client.resolve(aci: target, credentials: account().credentials, configuration: configuration())
            XCTFail("Accepted another member's response")
        } catch { XCTAssertEqual(error as? BConnectedEnrollmentError, .invalidResponse) }
    }

    func testDirectoryErrorsNeverBecomeSuccessfulEmptyResults() async throws {
        let http = DirectoryHTTP(data: try BConnectedEnrollmentWire.encode(["members": [], "nextOffset": NSNull()]))
        let client = BConnectedDirectoryClient(http: http)
        for status in [401, 404, 429, 503] {
            http.status = status
            do {
                _ = try await client.search(query: "", offset: 0, credentials: account().credentials, configuration: configuration())
                XCTFail("Treated an error as an empty directory")
            } catch { XCTAssertEqual(error as? BConnectedEnrollmentError, .unavailable) }
        }
    }

    func testLocalDirectoryCacheIsAccountScopedAndDoesNotCreateProfilesOrNicknames() throws {
        let originalContext = CurrentAppContext()
        SetCurrentAppContext(TestAppContext(), isRunningTests: true)
        let db = InMemoryDB()
        SetCurrentAppContext(originalContext, isRunningTests: true)
        let store = BConnectedDirectoryNameStore()
        let instant = Date(timeIntervalSince1970: 1_700_000_000)
        let before = db.read { tx in
            (try! Int.fetchOne(tx.database, sql: "SELECT count(*) FROM model_OWSUserProfile"),
             try! Int.fetchOne(tx.database, sql: "SELECT count(*) FROM NicknameRecord"))
        }
        db.write { tx in try! store.save(member(), ownerACI: owner, now: instant, tx: tx) }
        db.read { tx in
            XCTAssertEqual(store.member(aci: target, ownerACI: owner, tx: tx), member())
            XCTAssertNil(store.member(aci: target, ownerACI: otherOwner, tx: tx))
            XCTAssertFalse(store.needsRefresh(aci: target, ownerACI: owner, now: instant, tx: tx))
            XCTAssertTrue(store.needsRefresh(aci: target, ownerACI: owner, now: instant.addingTimeInterval(86400), tx: tx))
            XCTAssertEqual(try! Int.fetchOne(tx.database, sql: "SELECT count(*) FROM model_OWSUserProfile"), before.0)
            XCTAssertEqual(try! Int.fetchOne(tx.database, sql: "SELECT count(*) FROM NicknameRecord"), before.1)
        }
        XCTAssertEqual(DisplayName.directoryName(member().fullName).resolvedValue(), member().fullName)
        XCTAssertTrue(DisplayName.directoryName(member().fullName).hasKnownValue)
        XCTAssertFalse(DisplayName.directoryName(member().fullName).hasProfileNameOrBetter)
    }

    @MainActor
    func testHydrationDeduplicatesAndLimitsEachForegroundWithoutEnumerating() async throws {
        let account = try account()
        var calls: [String] = []
        var saved: [String] = []
        var instant = Date(timeIntervalSince1970: 1_700_000_000)
        let resolver = BConnectedDirectoryNameResolver(isActive: true, currentAccount: { account },
            resolve: { aci, _ in calls.append(aci); return self.member(aci) },
            persist: { member, _ in saved.append(member.aci) }, now: { instant })
        let ids = (1...25).map { String(format: "00000000-0000-4000-8000-%012d", $0) }
        for aci in ids { resolver.enqueueIfNeeded(aci: aci); resolver.enqueueIfNeeded(aci: aci) }
        await resolver.waitUntilIdleForTesting()
        XCTAssertEqual(calls, Array(ids.prefix(20)))
        XCTAssertEqual(saved, calls)
        resolver.setActive(false)
        resolver.setActive(true)
        resolver.enqueueIfNeeded(aci: ids[0])
        await resolver.waitUntilIdleForTesting()
        XCTAssertEqual(calls.count, 20)
        instant = instant.addingTimeInterval(301)
        resolver.enqueueIfNeeded(aci: ids[0])
        await resolver.waitUntilIdleForTesting()
        XCTAssertEqual(calls.count, 21)
    }

    @MainActor
    func testBackgroundCancelsHydrationAndLateResponseCannotWrite() async throws {
        let account = try account()
        let started = expectation(description: "resolution started")
        var continuation: CheckedContinuation<BConnectedDirectoryMember, Never>?
        var writes = 0
        let resolver = BConnectedDirectoryNameResolver(isActive: true, currentAccount: { account },
            resolve: { _, _ in await withCheckedContinuation { continuation = $0; started.fulfill() } },
            persist: { _, _ in writes += 1 })
        resolver.enqueueIfNeeded(aci: target)
        await fulfillment(of: [started], timeout: 1)
        let pending = try XCTUnwrap(resolver.currentTaskForTesting)
        resolver.setActive(false)
        resolver.enqueueIfNeeded(aci: otherOwner)
        continuation?.resume(returning: member())
        await pending.value
        XCTAssertEqual(writes, 0)
        XCTAssertNil(resolver.currentTaskForTesting)
    }

    @MainActor
    func testCredentialChangeDuringHydrationCannotWriteOldAccountMetadata() async throws {
        var current = try account()
        let started = expectation(description: "resolution started")
        var continuation: CheckedContinuation<BConnectedDirectoryMember, Never>?
        var writes = 0
        let resolver = BConnectedDirectoryNameResolver(isActive: true, currentAccount: { current },
            resolve: { _, _ in await withCheckedContinuation { continuation = $0; started.fulfill() } },
            persist: { _, _ in writes += 1 })
        resolver.enqueueIfNeeded(aci: target)
        await fulfillment(of: [started], timeout: 1)
        current = try account(passwordByte: 8)
        continuation?.resume(returning: member())
        await resolver.waitUntilIdleForTesting()
        XCTAssertEqual(writes, 0)
    }
}

private final class DirectoryHTTP: BConnectedOwnedHTTPSending {
    var data: Data
    var status = 200
    var requests: [URLRequest] = []
    init(data: Data) { self.data = data }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        requests.append(request)
        return (data, status)
    }
}
