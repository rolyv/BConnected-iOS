// Copyright 2026 BConnected contributors. SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import XCTest
@testable import SignalServiceKit

final class BConnectedRecipientLookupTest: XCTestCase, @unchecked Sendable {
    private let requestedACI = "abcdefab-cdef-4abc-8def-abcdefabcdef"
    private let primaryACI = "bcdefabc-defa-4bcd-8efa-bcdefabcdefa"

    private func configuration() throws -> BConnectedPublicationConfiguration {
        try BConnectedPublicationConfiguration(origin: URL(string: "https://owned.example.invalid")!,
            authorityCommitment: Data(repeating: 7, count: 32))
    }

    private func credentials() throws -> BConnectedPrimaryRecipientCredentials {
        try BConnectedPrimaryRecipientCredentials(aci: primaryACI,
            password: Data(repeating: 9, count: 32).base64EncodedString(), deviceId: 1,
            userAgent: "BConnectedTest/1", signalAgent: "OWI")
    }

    private func response(aci: String? = nil, deviceId: Int = 1) throws -> Data {
        try BConnectedEnrollmentWire.encode(["aci": aci ?? requestedACI, "deviceId": deviceId])
    }

    func testLookupUsesExactRouteAndExplicitCurrentPrimaryCredentials() async throws {
        let http = RecipientLookupHTTP(result: (try response(), 200))
        let client = BConnectedRecipientLookupClient(http: http)
        let recipient = try await client.lookup(recipientACI: requestedACI, credentials: credentials(), configuration: configuration())

        XCTAssertEqual(recipient, BConnectedRecipient(aci: requestedACI, deviceId: 1))
        let request = try XCTUnwrap(http.lastRequest)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.httpBody)
        XCTAssertEqual(request.url?.scheme, "https")
        XCTAssertEqual(request.url?.host, "owned.example.invalid")
        XCTAssertEqual(request.url?.path, "/v1/bconnected/recipients/\(requestedACI)")
        XCTAssertNil(request.url?.query)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic " +
            Data((primaryACI + ":" + Data(repeating: 9, count: 32).base64EncodedString()).utf8).base64EncodedString())
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "BConnectedTest/1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Signal-Agent"), "OWI")
    }

    func testLookupRejectsNoncanonicalTargetBeforeSending() async throws {
        let http = RecipientLookupHTTP(result: (try response(), 200))
        let client = BConnectedRecipientLookupClient(http: http)
        do {
            _ = try await client.lookup(recipientACI: requestedACI.uppercased(), credentials: credentials(), configuration: configuration())
            XCTFail("accepted a noncanonical ACI")
        } catch let error as BConnectedEnrollmentError {
            XCTAssertEqual(error, .invalidInput)
        }
        XCTAssertNil(http.lastRequest)
    }

    func testPrimaryCredentialsRequireCanonicalPrimaryACIValidPasswordAndDeviceOne() throws {
        let password = Data(repeating: 9, count: 32).base64EncodedString()
        XCTAssertThrowsError(try BConnectedPrimaryRecipientCredentials(aci: primaryACI.uppercased(), password: password,
            deviceId: 1, userAgent: "BConnectedTest/1", signalAgent: "OWI"))
        XCTAssertThrowsError(try BConnectedPrimaryRecipientCredentials(aci: primaryACI, password: "bad",
            deviceId: 1, userAgent: "BConnectedTest/1", signalAgent: "OWI"))
        XCTAssertThrowsError(try BConnectedPrimaryRecipientCredentials(aci: primaryACI, password: password,
            deviceId: 2, userAgent: "BConnectedTest/1", signalAgent: "OWI"))
    }

    func testResponseRequiresExactCanonicalACIAndPrimaryDeviceOne() throws {
        XCTAssertEqual(try BConnectedRecipientLookupClient.validateResponse(try response(), status: 200,
            requestedACI: requestedACI), BConnectedRecipient(aci: requestedACI, deviceId: 1))

        let invalidBodies: [Data] = [
            Data("{\"aci\":\"\(requestedACI)\",\"deviceId\":1,\"other\":true}".utf8),
            Data("{\"aci\":\"\(requestedACI)\"}".utf8),
            Data("{\"aci\":\"\(requestedACI.uppercased())\",\"deviceId\":1}".utf8),
            Data("{\"aci\":\"cdefabcd-efab-4cde-8fab-cdefabcdefab\",\"deviceId\":1}".utf8),
            Data("{\"aci\":\"\(requestedACI)\",\"deviceId\":2}".utf8),
            Data("{\"aci\":\"\(requestedACI)\",\"deviceId\":true}".utf8),
            Data("{\"aci\":\"\(requestedACI)\",\"deviceId\":1.0}".utf8),
            Data("{\"aci\":\"\(requestedACI)\",\"deviceId\":1,\"ac\\u0069\":\"\(requestedACI)\"}".utf8),
            Data(repeating: 32, count: BConnectedEnrollmentWire.maximumBytes + 1),
            Data([0xff]),
            Data("[]".utf8),
        ]
        for body in invalidBodies {
            XCTAssertThrowsError(try BConnectedRecipientLookupClient.validateResponse(body, status: 200,
                requestedACI: requestedACI))
        }
        for status in [201, 204, 304, 401, 404, 500] {
            XCTAssertThrowsError(try BConnectedRecipientLookupClient.validateResponse(try response(), status: status,
                requestedACI: requestedACI))
        }
    }

    func testOwnedHTTPRequiresNoStoreResponseForRecipientLookup() async throws {
        RecipientLookupURLProtocol.responseBody = try response()
        RecipientLookupURLProtocol.status = 200
        RecipientLookupURLProtocol.noStore = false
        let config = try configuration()
        let client = BConnectedRecipientLookupClient(http: BConnectedOwnedHTTP(
            protocolClasses: [RecipientLookupURLProtocol.self], responseMode: .enrollmentJSON))
        do {
            _ = try await client.lookup(recipientACI: requestedACI, credentials: credentials(), configuration: config)
            XCTFail("accepted a cacheable lookup response")
        } catch let error as BConnectedEnrollmentError {
            XCTAssertEqual(error, .invalidResponse)
        }

        RecipientLookupURLProtocol.noStore = true
        let recipient = try await client.lookup(recipientACI: requestedACI, credentials: credentials(), configuration: config)
        XCTAssertEqual(recipient, BConnectedRecipient(aci: requestedACI, deviceId: 1))
    }
}

private final class RecipientLookupHTTP: BConnectedOwnedHTTPSending {
    let result: (Data, Int)
    var lastRequest: URLRequest?
    init(result: (Data, Int)) { self.result = result }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        lastRequest = request
        return result
    }
}

private final class RecipientLookupURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responseBody = Data()
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var noStore = true

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var headers = ["Content-Type": "application/json"]
        if Self.noStore { headers["Cache-Control"] = "no-store" }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil,
            headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
