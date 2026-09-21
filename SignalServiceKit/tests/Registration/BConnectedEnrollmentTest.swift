// Copyright 2026 BConnected contributors. SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import XCTest
@testable import SignalServiceKit

final class BConnectedEnrollmentTest: XCTestCase {
    private let operationId = "00000000-0000-4000-8000-000000000010"
    private let memberId = "00000000-0000-4000-8000-000000000001"
    private let challenge = "ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8"
    private let phone = "+13055550123"

    private func resource(_ name: String) throws -> Data {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle(for: Self.self)
        #endif
        return try Data(contentsOf: XCTUnwrap(bundle.url(forResource: name, withExtension: "json")))
    }
    private func input(agent: String = "BConnected original/1") -> BConnectedEnrollmentPreparation {
        .init(phone: phone, unidentifiedAccessKey: Data(repeating: 1, count: 16), apnsToken: nil,
              discoverableByPhoneNumber: false, signalAgent: "BConnected-iOS", userAgent: agent)
    }
    private func body(_ name: String) throws -> (Data, Int) {
        let root = try JSONSerialization.jsonObject(with: resource("mobile-enrollment-v1-responses")) as! [String: Any]
        let value = try XCTUnwrap((root["cases"] as! [[String: Any]]).first { $0["name"] as? String == name })
        return (try BConnectedEnrollmentWire.encode(value["body"] as! [String: Any]), value["httpStatus"] as! Int)
    }
    private func observation(_ name: String = "verification", operation: BConnectedEnrollmentOperation = .status) throws -> BConnectedEnrollmentObservation {
        let (data, status) = try body(name)
        return try BConnectedEnrollmentWire.response(data, status: status, operation: operation, expectedOperation: operationId, expectedPhone: phone)
    }

    func testExactServerRequestFixtureAndEverySharedInvalidMutation() throws {
        let fixture = try resource("mobile-enrollment-v1")
        try BConnectedEnrollmentWire.request(fixture, operation: .begin)
        let mutations = try JSONSerialization.jsonObject(with: resource("mobile-enrollment-v1-invalid")) as! [[String: Any]]
        func replace(_ object: inout [String: Any], path: ArraySlice<String>, value: Any) {
            let key = path.first!
            if path.count == 1 { object[key] = value }
            else { var next = object[key] as! [String: Any]; replace(&next, path: path.dropFirst(), value: value); object[key] = next }
        }
        for mutation in mutations {
            var root = try BConnectedEnrollmentWire.object(fixture)
            replace(&root, path: (mutation["path"] as! [String])[...], value: mutation["value"]!)
            let data = try JSONSerialization.data(withJSONObject: root)
            XCTAssertThrowsError(try BConnectedEnrollmentWire.request(data, operation: .begin), mutation["name"] as! String)
        }
    }

    func testRejectsDuplicateEscapedDuplicateTrailingMalformedAndOversizedJSON() throws {
        for text in [#"{"a":1,"a":2}"#, #"{"a":1,"\u0061":2}"#, #"{"a":{"z":1,"z":2}}"#, #"{"a":1}{}"#, #"{"a":"\uD800"}"#, #"{"a":1.0}"#, #"{"a":1e0}"#] {
            XCTAssertThrowsError(try BConnectedEnrollmentWire.object(Data(text.utf8)))
        }
        XCTAssertThrowsError(try BConnectedEnrollmentWire.object(Data([123,34,255,34,58,49,125])))
        XCTAssertThrowsError(try BConnectedEnrollmentWire.object(Data(repeating: 32, count: 65_537)))
    }

    func testAllSharedResponseFixturesAndNullMeansUnavailable() throws {
        let root = try JSONSerialization.jsonObject(with: resource("mobile-enrollment-v1-responses")) as! [String: Any]
        for item in root["cases"] as! [[String: Any]] {
            let data = try BConnectedEnrollmentWire.encode(item["body"] as! [String: Any])
            let status = item["httpStatus"] as! Int
            if status >= 400 {
                XCTAssertThrowsError(try BConnectedEnrollmentWire.response(data, status: status, operation: .status, expectedOperation: operationId, expectedPhone: phone)) {
                    guard case .rejected = $0 as? BConnectedEnrollmentError else { return XCTFail("Expected a typed public error") }
                }
            } else {
                _ = try BConnectedEnrollmentWire.response(data, status: status, operation: status == 202 ? .complete : .status, expectedOperation: operationId, expectedPhone: phone)
            }
        }
        let verified = try observation("phone_verified")
        XCTAssertTrue(verified.phoneVerified == true)
        XCTAssertNil(verified.nextSmsSeconds)
        XCTAssertFalse(verified.registrationAuthorized)
        XCTAssertNil(verified.account)
    }

    func testRejectsForgedActivationOtherOperationPhoneDeviceAndUnknownFields() throws {
        let (data, _) = try body("active")
        var root = try BConnectedEnrollmentWire.object(data)
        func rejected(_ root: [String: Any], status: Int = 200) throws {
            XCTAssertThrowsError(try BConnectedEnrollmentWire.response(BConnectedEnrollmentWire.encode(root), status: status, operation: .status, expectedOperation: operationId, expectedPhone: phone))
        }
        root["registrationAuthorized"] = false; try rejected(root)
        root = try BConnectedEnrollmentWire.object(data); root["operationId"] = memberId; try rejected(root)
        root = try BConnectedEnrollmentWire.object(data); root["permit"] = "forbidden"; try rejected(root)
        for (key, value) in [("deviceId", 2 as Any), ("number", "+13055559999" as Any), ("extra", true as Any)] {
            root = try BConnectedEnrollmentWire.object(data); var account = root["account"] as! [String: Any]
            account[key] = value; root["account"] = account; try rejected(root)
        }
        root = try BConnectedEnrollmentWire.object(body("verification").0)
        root["registrationAuthorized"] = true; try rejected(root)
        root = try BConnectedEnrollmentWire.object(body("verification").0)
        root["nextSmsSeconds"] = -1; try rejected(root)
        let invalid = try body("invalid_credentials")
        XCTAssertThrowsError(try BConnectedEnrollmentWire.response(invalid.0, status: 503, operation: .status, expectedOperation: operationId, expectedPhone: phone)) {
            XCTAssertEqual($0 as? BConnectedEnrollmentError, .invalidResponse)
        }
    }

    @MainActor
    func testRestartPreservesEverySecretPublicByteAndOriginalMetadata() throws {
        let store = MemoryStore(), sender = Sender()
        let first = BConnectedEnrollmentCoordinator(persistence: store, client: sender)
        let intent = try first.prepare(input())
        let original = try XCTUnwrap(store.bytes)
        let restarted = BConnectedEnrollmentCoordinator(persistence: store, client: sender)
        XCTAssertEqual(try restarted.prepare(input(agent: "BConnected updated/2")), intent)
        XCTAssertEqual(store.bytes, original)
        try restarted.bindApprovedIntent(memberId: memberId, challenge: challenge)
        let record = try store.load()!
        let json = try BConnectedEnrollmentWire.request(record.body(for: .begin, code: nil), operation: .begin)
        XCTAssertEqual(json["originalUserAgent"] as? String, "BConnected original/1")
        XCTAssertEqual(record.registrationRequest, try JSONDecoder().decode(BConnectedEnrollmentRecord.self, from: original).registrationRequest)
        XCTAssertFalse(record.sendNeedsExplicitDecision)
        XCTAssertNil(record.observation)
        XCTAssertTrue(sender.calls.isEmpty)
    }

    @MainActor
    func testPersistenceFailureAndCorruptionStopBeforeNetworkOrIntent() async throws {
        let store = MemoryStore(), sender = Sender()
        let coordinator = BConnectedEnrollmentCoordinator(persistence: store, client: sender)
        store.failCommit = true
        XCTAssertThrowsError(try coordinator.prepare(input()))
        XCTAssertNil(store.bytes)
        store.failCommit = false; _ = try coordinator.prepare(input())
        try coordinator.bindApprovedIntent(memberId: memberId, challenge: challenge)
        store.failCommit = true
        do { _ = try await coordinator.perform(.begin); XCTFail() } catch {}
        XCTAssertTrue(sender.calls.isEmpty)
        store.failCommit = false; store.bytes = Data("corrupt".utf8)
        XCTAssertThrowsError(try coordinator.prepare(input()))
        XCTAssertEqual(store.bytes, Data("corrupt".utf8))
    }

    @MainActor
    func testAmbiguousSMSRestartStatusDoesNotResendAndExplicitResendRetainsMaterial() async throws {
        let store = MemoryStore(), sender = Sender()
        let coordinator = BConnectedEnrollmentCoordinator(persistence: store, client: sender)
        _ = try coordinator.prepare(input()); try coordinator.bindApprovedIntent(memberId: memberId, challenge: challenge)
        sender.result = try observation()
        _ = try await coordinator.perform(.begin)
        let original = try store.load()!
        sender.error = BConnectedEnrollmentError.unavailable
        do { _ = try await coordinator.perform(.sendCode); XCTFail() } catch {}
        XCTAssertTrue(try store.load()!.sendNeedsExplicitDecision)
        let restarted = BConnectedEnrollmentCoordinator(persistence: store, client: sender)
        sender.error = nil
        _ = try await restarted.perform(.status)
        do { _ = try await restarted.perform(.sendCode); XCTFail() }
        catch { XCTAssertEqual(error as? BConnectedEnrollmentError, .explicitSendRequired) }
        XCTAssertEqual(sender.calls, [.begin, .sendCode, .status])
        _ = try await restarted.perform(.sendCode, explicitlyResendAfterUncertainOutcome: true)
        let final = try store.load()!
        XCTAssertFalse(final.sendNeedsExplicitDecision)
        XCTAssertEqual(final.password, original.password)
        XCTAssertEqual(final.registrationRequest, original.registrationRequest)
        XCTAssertEqual(final.aci.pair, original.aci.pair)
        XCTAssertEqual(final.pni.lastResortPreKey, original.pni.lastResortPreKey)
    }

    @MainActor
    func testPhoneVerificationPendingActiveRemainDistinctAndErrorsNeverEraseKeys() async throws {
        let store = MemoryStore(), sender = Sender()
        let coordinator = BConnectedEnrollmentCoordinator(persistence: store, client: sender)
        _ = try coordinator.prepare(input()); try coordinator.bindApprovedIntent(memberId: memberId, challenge: challenge)
        sender.result = try observation("phone_verified"); let verified = try await coordinator.perform(.begin)
        XCTAssertFalse(verified.registrationAuthorized)
        sender.result = try observation("pending_confirmation", operation: .complete)
        let pending = try await coordinator.perform(.complete)
        XCTAssertEqual(pending.state, .pendingConfirmation); XCTAssertNil(pending.account)
        let material = try store.load()!.registrationRequest
        for code in [BConnectedEnrollmentError.Code.enrollmentExpired, .invalidCredentials, .enrollmentConflict, .temporarilyUnavailable] {
            sender.error = BConnectedEnrollmentError.rejected(code, retryAfterSeconds: nil)
            do { _ = try await coordinator.perform(.status); XCTFail() } catch {}
            XCTAssertEqual(try store.load()!.registrationRequest, material)
        }
        sender.error = nil; sender.result = try observation("active")
        let active = try await coordinator.perform(.status)
        XCTAssertEqual(active.account?.deviceId, 1)
        #if SWIFT_PACKAGE
        // The host harness compiles the exact app view-model source beside these tests.
        let callCount = sender.calls.count
        let model = BConnectedEnrollmentViewModel(info: ["BConnectedEnrollmentOrigin": "https://enrollment.example.invalid"]) { _ in coordinator }
        XCTAssertEqual(model.title, "Account confirmed")
        XCTAssertTrue(model.detail.contains("Finishing device setup is not available"))
        XCTAssertFalse(model.busy)
        XCTAssertEqual(sender.calls.count, callCount)
        #endif
        // The coordinator has no TSAccountManager dependency or registration-completion side effect.
    }

    @MainActor
    func testMissingBindingMissingOperationImmutableBindingAndCodeValidationStopDispatch() async throws {
        let store = MemoryStore(), sender = Sender()
        let coordinator = BConnectedEnrollmentCoordinator(persistence: store, client: sender)
        _ = try coordinator.prepare(input())
        do { _ = try await coordinator.perform(.begin); XCTFail() } catch {}
        try coordinator.bindApprovedIntent(memberId: memberId, challenge: challenge)
        XCTAssertThrowsError(try coordinator.bindApprovedIntent(memberId: operationId, challenge: challenge))
        do { _ = try await coordinator.perform(.status); XCTFail() } catch {}
        XCTAssertTrue(sender.calls.isEmpty)
        sender.result = try observation(); _ = try await coordinator.perform(.begin)
        for code in [nil, "", "１２３４", "123", "12345678901", "1\n23"] as [String?] {
            do { _ = try await coordinator.perform(.checkCode, code: code); XCTFail() } catch {}
        }
        do { _ = try await coordinator.perform(.status, code: "12345"); XCTFail() } catch {}
        XCTAssertEqual(sender.calls, [.begin])
    }

    @MainActor
    func testResponsePersistenceFailureAndCancellationRetainDispatchMarker() async throws {
        let store = MemoryStore(), sender = Sender()
        let coordinator = BConnectedEnrollmentCoordinator(persistence: store, client: sender)
        _ = try coordinator.prepare(input()); try coordinator.bindApprovedIntent(memberId: memberId, challenge: challenge)
        sender.result = try observation(); _ = try await coordinator.perform(.begin)
        sender.beforeReturn = { store.failCommit = true }
        do { _ = try await coordinator.perform(.sendCode); XCTFail() } catch {}
        store.failCommit = false; sender.beforeReturn = nil
        XCTAssertTrue(try coordinator.progress()!.smsOutcomeNeedsExplicitDecision)
        sender.error = CancellationError()
        do { _ = try await coordinator.perform(.sendCode, explicitlyResendAfterUncertainOutcome: true); XCTFail() }
        catch { XCTAssertEqual(error as? BConnectedEnrollmentError, .unavailable) }
        XCTAssertTrue(try coordinator.progress()!.smsOutcomeNeedsExplicitDecision)
    }

    func testRealURLSessionBoundsBodyRejectsRedirectAndSanitizesUnexpected401() async throws {
        var record = try BConnectedEnrollmentRecord.generate(input())
        record.binding = .init(memberId: memberId, challenge: challenge)
        record.operationId = operationId
        let fixture = try body("verification").0
        let endpoint = try BConnectedEnrollmentEndpoint(origin: URL(string: "https://enrollment.example.invalid")!)
        defer { EnrollmentURLProtocol.responseBody = Data(); EnrollmentURLProtocol.redirect = false }
        for scenario in ["valid", "missing-no-store", "oversized", "iam-401", "redirect", "typed-401"] {
            EnrollmentURLProtocol.calls = 0
            EnrollmentURLProtocol.responseBody = scenario == "oversized" ? Data(repeating: 32, count: 65_537) : fixture
            EnrollmentURLProtocol.status = scenario.contains("401") ? 401 : 200
            EnrollmentURLProtocol.noStore = scenario != "missing-no-store"
            EnrollmentURLProtocol.redirect = scenario == "redirect"
            if scenario == "iam-401" { EnrollmentURLProtocol.responseBody = Data("<html>Denied</html>".utf8) }
            if scenario == "typed-401" { EnrollmentURLProtocol.responseBody = try body("invalid_credentials").0 }
            let client = BConnectedEnrollmentClient(endpoint: endpoint, protocolClasses: [EnrollmentURLProtocol.self])
            do {
                let result = try await client.send(.status, record: record, code: nil)
                XCTAssertEqual(scenario, "valid"); XCTAssertFalse(result.registrationAuthorized)
            } catch {
                XCTAssertNotEqual(scenario, "valid")
                if scenario == "typed-401" {
                    XCTAssertEqual(error as? BConnectedEnrollmentError, .rejected(.invalidCredentials, retryAfterSeconds: nil))
                } else { XCTAssertEqual(error as? BConnectedEnrollmentError, .invalidResponse) }
            }
            XCTAssertEqual(EnrollmentURLProtocol.calls, 1, "Never follow a redirect or automatically retry")
        }
    }

    func testRequestIsExplicitOwnedHTTPSAndNeverSerializesPrivateMaterial() throws {
        var record = try BConnectedEnrollmentRecord.generate(input())
        record.binding = .init(memberId: memberId, challenge: challenge)
        record.operationId = operationId
        let client = BConnectedEnrollmentClient(endpoint: try .init(origin: URL(string: "https://enrollment.example.invalid:8443")!))
        let request = try client.request(.checkCode, record: record, code: "12345")
        XCTAssertEqual(request.url?.absoluteString, "https://enrollment.example.invalid:8443/v1/bconnected/enrollment/\(operationId)/check-code")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic " + Data((phone + ":" + record.password).utf8).base64EncodedString())
        let body = String(decoding: request.httpBody!, as: UTF8.self)
        for secret in [record.password, record.aci.pair.base64EncodedString(), record.pni.signedPreKey.base64EncodedString()] { XCTAssertFalse(body.contains(secret)) }
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        for url in ["http://enrollment.example.invalid", "https://u:p@example.invalid", "https://example.invalid/chat", "https://example.invalid?q=1", "https://example.invalid#secret"] {
            XCTAssertThrowsError(try BConnectedEnrollmentEndpoint(origin: URL(string: url)!))
        }
    }
}

private final class MemoryStore: BConnectedEnrollmentPersistence {
    var bytes: Data?
    var failCommit = false
    func load() throws -> BConnectedEnrollmentRecord? { try bytes.map { try JSONDecoder().decode(BConnectedEnrollmentRecord.self, from: $0) } }
    func transaction<T>(_ update: (inout BConnectedEnrollmentRecord?) throws -> T) throws -> T {
        var record = try load(); try record?.validate()
        let result = try update(&record)
        if failCommit { throw BConnectedEnrollmentError.persistenceUnavailable }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        bytes = try encoder.encode(record)
        return result
    }
}
private final class Sender: BConnectedEnrollmentSending {
    var calls: [BConnectedEnrollmentOperation] = []
    var error: Error?
    var result: BConnectedEnrollmentObservation?
    var beforeReturn: (() -> Void)?
    func send(_ operation: BConnectedEnrollmentOperation, record: BConnectedEnrollmentRecord, code: String?) async throws -> BConnectedEnrollmentObservation {
        calls.append(operation)
        if let error { throw error }
        beforeReturn?()
        return try XCTUnwrap(result)
    }
}

// URLProtocol intercepts every request; no DNS, TLS, SMS, or external service is used.
private final class EnrollmentURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responseBody = Data()
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var noStore = true
    nonisolated(unsafe) static var redirect = false
    nonisolated(unsafe) static var calls = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.calls += 1
        var headers = ["Content-Type": "application/json"]
        if Self.noStore { headers["Cache-Control"] = "no-store" }
        if Self.redirect {
            let response = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: nil,
                                           headerFields: ["Location": "https://elsewhere.example.invalid"])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: URL(string: "https://elsewhere.example.invalid")!), redirectResponse: response)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
