// Copyright 2026 BConnected contributors. SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import XCTest
import LibSignalClient
@testable import SignalServiceKit

// Test-instance state is immutable; mutable protocol fixtures are scoped to individual tests.
final class BConnectedEnrollmentTest: XCTestCase, @unchecked Sendable {
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

    @MainActor
    private func publicationFixture() async throws -> (MemoryStore, Sender, PublicationSender, BConnectedEnrollmentCoordinator) {
        let store = MemoryStore(), sender = Sender(), publisher = PublicationSender()
        store.supportsNativeInstallation = true
        let configuration = try BConnectedPublicationConfiguration(origin: URL(string: "https://publication.example.invalid:8443")!, authorityCommitment: Data(repeating: 1, count: 32))
        let coordinator = BConnectedEnrollmentCoordinator(persistence: store, client: sender, publicationConfiguration: configuration, publisher: publisher)
        _ = try coordinator.prepare(input()); try coordinator.bindApprovedIntent(memberId: memberId, challenge: challenge)
        sender.result = try observation("active"); _ = try await coordinator.perform(.begin)
        try await coordinator.installNativeAccount(); try coordinator.prepareLocalAccount(); try coordinator.prepareAccountEntropy()
        sender.calls = []
        return (store, sender, publisher, coordinator)
    }

    @MainActor
    func testPublicationCommitsDispatchBeforeEachRequestAndNeverCompletesReadiness() async throws {
        let (store, sender, publisher, coordinator) = try await publicationFixture()
        publisher.beforeSend = { step, record in
            XCTAssertEqual(try store.load()?.publication, record.publication)
            XCTAssertEqual(record.publication?.state(for: step), .dispatched)
        }
        try await coordinator.publishAccount()
        XCTAssertEqual(sender.calls, [.status]); XCTAssertEqual(publisher.steps, [.attributes, .profile])
        XCTAssertTrue(try XCTUnwrap(coordinator.progress()).accountPublicationComplete)
        let original = try store.load()
        try await coordinator.publishAccount()
        XCTAssertEqual(publisher.steps, [.attributes, .profile])
        XCTAssertEqual(try store.load()?.publication, original?.publication)
        XCTAssertEqual(try store.load()?.aci.pair, original?.aci.pair)
    }

    @MainActor
    func testUncertainProfileRequiresExplicitReplayOfIdenticalFrozenBytes() async throws {
        let (store, _, publisher, coordinator) = try await publicationFixture()
        publisher.failStep = .profile
        do { try await coordinator.publishAccount(); XCTFail() } catch {}
        let saved = try XCTUnwrap(store.load()?.publication)
        XCTAssertEqual(saved.attributesState, .acknowledged); XCTAssertEqual(saved.profileState, .dispatched)
        do { try await coordinator.publishAccount(); XCTFail() }
        catch { XCTAssertEqual(error as? BConnectedEnrollmentError, .explicitPublicationRetryRequired) }
        XCTAssertEqual(publisher.steps, [.attributes, .profile])
        publisher.failStep = nil
        try await coordinator.publishAccount(explicitlyRetryUncertainOutcome: true)
        XCTAssertEqual(publisher.steps, [.attributes, .profile, .profile])
        XCTAssertEqual(publisher.bodies[1], publisher.bodies[2])
        XCTAssertEqual(try store.load()?.publication?.encryptedProfile, saved.encryptedProfile)
    }

    @MainActor
    func testPublicationResponsePersistenceFailureRetainsMarkerAndSuspensionStopsReplay() async throws {
        let (store, sender, publisher, coordinator) = try await publicationFixture()
        store.failPublicationAcknowledgement = true
        do { try await coordinator.publishAccount(); XCTFail() } catch {}
        XCTAssertEqual(publisher.steps, [.attributes])
        XCTAssertEqual(try store.load()?.publication?.attributesState, .dispatched)
        sender.result = try observation("suspended")
        do { try await coordinator.publishAccount(explicitlyRetryUncertainOutcome: true); XCTFail() } catch {}
        XCTAssertEqual(publisher.steps, [.attributes])
        sender.result = try observation("active"); store.failPublicationAcknowledgement = false
        try await coordinator.publishAccount(explicitlyRetryUncertainOutcome: true)
        XCTAssertEqual(publisher.steps, [.attributes, .attributes, .profile])
        XCTAssertEqual(publisher.bodies[0], publisher.bodies[1])
    }

    @MainActor
    func testMissingPublicationConfigurationMakesNoStatusOrPublicationCalls() async throws {
        let store = MemoryStore(), sender = Sender(), publisher = PublicationSender()
        store.supportsNativeInstallation = true
        let coordinator = BConnectedEnrollmentCoordinator(persistence: store, client: sender, publisher: publisher)
        do { try await coordinator.publishAccount(); XCTFail() } catch {}
        XCTAssertTrue(sender.calls.isEmpty && publisher.steps.isEmpty)
    }

    func testPublicationOriginRejectsUnsafeAndUpstreamRoutes() throws {
        for string in ["http://example.invalid", "https://u:p@example.invalid", "https://example.invalid/path", "https://example.invalid?q=1", "https://example.invalid#f", "https://chat.signal.org", "https://signal.org", "https://cdn.whispersystems.org", "https://-a.invalid", "https://a..invalid"] {
            XCTAssertThrowsError(try BConnectedPublicationConfiguration(origin: URL(string: string)!, authorityCommitment: Data(repeating: 1, count: 32)))
        }
        let one = try BConnectedPublicationConfiguration(origin: URL(string: "https://example.invalid:443/")!, authorityCommitment: Data(repeating: 1, count: 32))
        let two = try BConnectedPublicationConfiguration(origin: URL(string: "https://example.invalid")!, authorityCommitment: Data(repeating: 1, count: 32))
        XCTAssertEqual(one.hash, two.hash)
        XCTAssertNotEqual(one.hash, try BConnectedPublicationConfiguration(origin: one.origin, authorityCommitment: Data(repeating: 2, count: 32)).hash)
    }

    @MainActor
    private func publishedRecordBytes() async throws -> Data {
        let (store, _, _, coordinator) = try await publicationFixture()
        try await coordinator.publishAccount()
        return try JSONEncoder().encode(XCTUnwrap(store.load()))
    }

    func testPublicationClientUsesExactRoutesCredentialsPayloadsAndEmptySuccessContract() async throws {
        var record = try JSONDecoder().decode(BConnectedEnrollmentRecord.self, from: await publishedRecordBytes())
        record.publication?.attributesState = .dispatched; record.publication?.profileState = .prepared
        let config = try BConnectedPublicationConfiguration(origin: URL(string: "https://publication.example.invalid:8443")!, authorityCommitment: Data(repeating: 1, count: 32))
        let http = PublicationHTTP(), client = BConnectedPublicationClient(http: http)
        let request = try client.request(.attributes, record: record, configuration: config)
        XCTAssertEqual(request.url?.absoluteString, "https://publication.example.invalid:8443/v1/accounts/attributes/")
        XCTAssertEqual(request.httpMethod, "PUT"); XCTAssertEqual(request.httpBody, record.publication?.accountAttributes)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic " + Data((record.installedAccount!.aci + ":" + record.password).utf8).base64EncodedString())
        XCTAssertNil(try BConnectedEnrollmentWire.object(request.httpBody!)["recoveryPassword"])
        try await client.send(.attributes, record: record, configuration: config)
        for response in [(Data(), 200), (Data(), 301), (Data(), 401), (Data("{}".utf8), 204)] {
            http.result = response
            do { try await client.send(.attributes, record: record, configuration: config); XCTFail() } catch {}
        }
        record.publication?.attributesState = .acknowledged; record.publication?.profileState = .dispatched
        http.result = (Data(), 200)
        try await client.send(.profile, record: record, configuration: config)
        XCTAssertEqual(http.lastRequest?.url?.path, "/v1/profile")
    }

    func testPublicationLedgerRejectsMalformedNativeProfileEvenWithRecomputedPayloadHash() async throws {
        let original = try JSONDecoder().decode(BConnectedEnrollmentRecord.self, from: await publishedRecordBytes())
        let ledger = try XCTUnwrap(original.publication)
        for (field, invalid): (String, Any) in [("name", Data([1]).base64EncodedString()), ("about", Data([1]).base64EncodedString()),
            ("aboutEmoji", Data([1]).base64EncodedString()), ("phoneNumberSharing", Data([1]).base64EncodedString()),
            ("version", String(repeating: "z", count: 64)), ("commitment", Data(repeating: 0, count: 32).base64EncodedString()),
            ("avatar", false), ("paymentAddress", "unexpected")] {
            var record = original
            var object = try BConnectedEnrollmentWire.object(ledger.encryptedProfile); object[field] = invalid
            let profile = try BConnectedEnrollmentWire.encode(object)
            record.publication = .init(version: ledger.version, configurationHash: ledger.configurationHash, entropyReceipt: ledger.entropyReceipt,
                profileStateHash: ledger.profileStateHash, accountAttributes: ledger.accountAttributes, encryptedProfile: profile,
                payloadHash: BConnectedEnrollmentRecord.Publication.hash(attributes: ledger.accountAttributes, profile: profile))
            XCTAssertThrowsError(try record.validate())
        }
    }

    func testPublicationURLSessionRejectsRedirectsAndOversizedBodiesWithoutAutomaticRetry() async throws {
        var record = try JSONDecoder().decode(BConnectedEnrollmentRecord.self, from: await publishedRecordBytes())
        record.publication?.attributesState = .dispatched; record.publication?.profileState = .prepared
        let config = try BConnectedPublicationConfiguration(origin: URL(string: "https://publication.example.invalid:8443")!, authorityCommitment: Data(repeating: 1, count: 32))
        let client = BConnectedPublicationClient(http: BConnectedOwnedHTTP(protocolClasses: [EnrollmentURLProtocol.self], responseMode: .emptyPublication))
        EnrollmentURLProtocol.noStore = false; EnrollmentURLProtocol.redirect = false
        EnrollmentURLProtocol.responseBody = Data(); EnrollmentURLProtocol.status = 204; EnrollmentURLProtocol.calls = 0
        defer { EnrollmentURLProtocol.noStore = true; EnrollmentURLProtocol.redirect = false; EnrollmentURLProtocol.responseBody = Data(); EnrollmentURLProtocol.status = 200 }
        try await client.send(.attributes, record: record, configuration: config)
        XCTAssertEqual(EnrollmentURLProtocol.calls, 1)
        EnrollmentURLProtocol.redirect = true
        do { try await client.send(.attributes, record: record, configuration: config); XCTFail() } catch {}
        XCTAssertEqual(EnrollmentURLProtocol.calls, 2)
        EnrollmentURLProtocol.redirect = false; EnrollmentURLProtocol.responseBody = Data(repeating: 0, count: 65_537)
        do { try await client.send(.attributes, record: record, configuration: config); XCTFail() } catch {}
        XCTAssertEqual(EnrollmentURLProtocol.calls, 3)
    }

    @MainActor
    func testAccountEntropyRequiresLocalReceiptAndSendsNothingAcrossRestart() async throws {
        let store = MemoryStore(), sender = Sender()
        let coordinator = BConnectedEnrollmentCoordinator(persistence: store, client: sender)
        XCTAssertThrowsError(try coordinator.prepareAccountEntropy())
        store.supportsNativeInstallation = true
        _ = try coordinator.prepare(input())
        XCTAssertThrowsError(try coordinator.prepareAccountEntropy())
        try coordinator.bindApprovedIntent(memberId: memberId, challenge: challenge)
        sender.result = try observation("active")
        _ = try await coordinator.perform(.begin)
        try await coordinator.installNativeAccount()
        XCTAssertThrowsError(try coordinator.prepareAccountEntropy())
        try coordinator.prepareLocalAccount()
        let requests = sender.calls
        store.failCommit = true
        XCTAssertThrowsError(try coordinator.prepareAccountEntropy())
        XCTAssertNil(try store.load()?.accountEntropyReceipt)
        store.failCommit = false
        try coordinator.prepareAccountEntropy()
        XCTAssertTrue(try XCTUnwrap(coordinator.progress()).accountEntropyPrepared)
        let receipt = try XCTUnwrap(store.load()?.accountEntropyReceipt)
        let restarted = BConnectedEnrollmentCoordinator(persistence: store, client: sender)
        try restarted.prepareAccountEntropy()
        XCTAssertEqual(try store.load()?.accountEntropyReceipt, receipt)
        XCTAssertEqual(sender.calls, requests)
    }

    @MainActor
    func testLocalPreparationIsSeparateFromRemoteAuthorizationAndSendsNothing() async throws {
        let store = MemoryStore(), sender = Sender()
        store.supportsNativeInstallation = true
        let coordinator = BConnectedEnrollmentCoordinator(persistence: store, client: sender)
        _ = try coordinator.prepare(input())
        XCTAssertThrowsError(try coordinator.prepareLocalAccount())
        XCTAssertTrue(sender.calls.isEmpty)
        try coordinator.bindApprovedIntent(memberId: memberId, challenge: challenge)
        sender.result = try observation("active")
        _ = try await coordinator.perform(.begin)
        try await coordinator.installNativeAccount()
        let requests = sender.calls
        let original = try XCTUnwrap(store.load())
        try coordinator.prepareLocalAccount()
        XCTAssertTrue(try XCTUnwrap(coordinator.progress()).localAccountPrepared)
        let first = try store.load()?.localSetupReceipt
        let restarted = BConnectedEnrollmentCoordinator(persistence: store, client: sender)
        try restarted.prepareLocalAccount()
        XCTAssertEqual(try store.load()?.localSetupReceipt, first)
        XCTAssertEqual(try store.load()?.password, original.password)
        XCTAssertEqual(try store.load()?.registrationRequest, original.registrationRequest)
        XCTAssertEqual(sender.calls, requests)
    }

    @MainActor
    func testNativeInstallRequiresFreshActiveStatusAndExactRestartMaterial() async throws {
        let store = MemoryStore(), sender = Sender()
        store.supportsNativeInstallation = true
        let coordinator = BConnectedEnrollmentCoordinator(persistence: store, client: sender)
        _ = try coordinator.prepare(input())
        try coordinator.bindApprovedIntent(memberId: memberId, challenge: challenge)
        sender.result = try observation("active")
        _ = try await coordinator.perform(.begin)
        let original = try XCTUnwrap(store.load())
        XCTAssertFalse(try XCTUnwrap(coordinator.progress()).nativeAccountInstalled)
        sender.result = try observation("suspended")
        do { try await coordinator.installNativeAccount(); XCTFail() } catch {}
        XCTAssertEqual(store.installCount, 0)
        sender.result = try observation("active")
        try await coordinator.installNativeAccount()
        XCTAssertEqual(store.installCount, 1)
        XCTAssertTrue(try XCTUnwrap(coordinator.progress()).nativeAccountInstalled)
        let installed = try XCTUnwrap(store.load())
        let restarted = BConnectedEnrollmentCoordinator(persistence: store, client: sender)
        _ = try restarted.prepare(input(agent: "new app version is not replacement metadata"))
        try await restarted.installNativeAccount()
        let final = try XCTUnwrap(store.load())
        XCTAssertEqual(store.installCount, 1)
        XCTAssertEqual(sender.calls, [.begin, .status, .status, .status])
        XCTAssertEqual(final.password, original.password)
        XCTAssertEqual(final.aci.pair, original.aci.pair)
        XCTAssertEqual(final.pni.lastResortPreKey, original.pni.lastResortPreKey)
        XCTAssertEqual(final.registrationRequest, original.registrationRequest)
        XCTAssertEqual(final.originalUserAgent, original.originalUserAgent)
        XCTAssertEqual(final.installedAccount, installed.installedAccount)
        XCTAssertEqual(final.operationId, original.operationId)
    }

    @MainActor
    func testNativeInstallUnavailablePersistenceFailureAndChangedAccountNeverMutate() async throws {
        let store = MemoryStore(), sender = Sender()
        let coordinator = BConnectedEnrollmentCoordinator(persistence: store, client: sender)
        do { try await coordinator.installNativeAccount(); XCTFail() } catch {}
        XCTAssertTrue(sender.calls.isEmpty)
        store.supportsNativeInstallation = true
        _ = try coordinator.prepare(input())
        try coordinator.bindApprovedIntent(memberId: memberId, challenge: challenge)
        sender.result = try observation("active")
        _ = try await coordinator.perform(.begin)
        store.failInstall = true
        do { try await coordinator.installNativeAccount(); XCTFail() } catch {}
        XCTAssertEqual(store.installCount, 0)
        XCTAssertNil(try store.load()?.installedAccount)
        store.failInstall = false
        try await coordinator.installNativeAccount()
        let saved = try XCTUnwrap(store.load()?.installedAccount)
        let (activeBytes, status) = try body("active")
        var value = try BConnectedEnrollmentWire.object(activeBytes)
        var account = value["account"] as! [String: Any]
        account["aci"] = memberId; value["account"] = account
        sender.result = try BConnectedEnrollmentWire.response(BConnectedEnrollmentWire.encode(value), status: status, operation: .status, expectedOperation: operationId, expectedPhone: phone)
        do { try await coordinator.installNativeAccount(); XCTFail() } catch {}
        XCTAssertEqual(store.installCount, 1)
        XCTAssertEqual(try store.load()?.installedAccount, saved)
        store.failCommit = true
        let count = sender.calls.count
        do { try await coordinator.installNativeAccount(); XCTFail() } catch {}
        XCTAssertEqual(sender.calls.count, count)
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
        XCTAssertTrue(model.detail.contains("Save the verified account"))
        XCTAssertFalse(try XCTUnwrap(coordinator.progress()).nativeAccountInstalled)
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

    @MainActor
    func testCommunityApprovalPrecedesPreparationAndIntentFollowsDurableKeys() async throws {
        let keys = MemoryStore(), signal = Sender(), membership = CommunityStore(), service = CommunitySender()
        let enrollment = BConnectedEnrollmentCoordinator(persistence: keys, client: signal)
        let community = BConnectedCommunityEnrollmentCoordinator(persistence: membership, client: service, enrollment: enrollment)
        try await community.apply(name: "Fixture Alumnus", year: 2000, invitation: challenge)
        XCTAssertEqual(try community.progress().member?.status, .pending)
        var preparations = 0
        do { try await community.connectApprovedMembership { preparations += 1; return self.input() }; XCTFail() } catch {}
        XCTAssertEqual(preparations, 0); XCTAssertNil(keys.bytes)
        service.status = .approved; try await community.refreshApproval()
        service.beforeIntent = { material in
            let record = try XCTUnwrap(keys.load())
            XCTAssertEqual(material.registrationAttemptId, record.attempt)
            XCTAssertEqual(material.keyCommitment, record.keyCommitment)
            XCTAssertNil(record.binding)
        }
        try await community.connectApprovedMembership { preparations += 1; return self.input() }
        XCTAssertEqual(preparations, 1)
        XCTAssertTrue(try enrollment.progress()!.hasApprovedIntentBinding)
        XCTAssertFalse(try enrollment.progress()!.hasOperation)
        XCTAssertNil(try enrollment.progress()!.lastObservation)
        XCTAssertTrue(signal.calls.isEmpty)
        #if SWIFT_PACKAGE
        let model = BConnectedEnrollmentViewModel(info: ["BConnectedEnrollmentOrigin": "https://enrollment.example.invalid", "BConnectedCommunityOrigin": "https://community.example.invalid"],
            makeCoordinator: { _ in enrollment }, makeCommunity: { _, _ in community }, makePreparation: { _ in self.input() })
        XCTAssertEqual(model.title, "Verify your phone")
        XCTAssertFalse(model.canApply)
        XCTAssertFalse(model.maySend)
        #endif
    }

    @MainActor
    func testLostCommunityApplicationResponseNeverConsumesAnotherInvitationAutomatically() async throws {
        let keys = MemoryStore(), signal = Sender(), membership = CommunityStore(), service = CommunitySender()
        let enrollment = BConnectedEnrollmentCoordinator(persistence: keys, client: signal)
        var community = BConnectedCommunityEnrollmentCoordinator(persistence: membership, client: service, enrollment: enrollment)
        membership.failCommit = true
        do { try await community.apply(name: "Fixture", year: 2000, invitation: challenge); XCTFail() } catch {}
        XCTAssertEqual(service.applications, 0)
        membership.failCommit = false; service.error = BConnectedEnrollmentError.unavailable
        do { try await community.apply(name: "Fixture", year: 2000, invitation: challenge); XCTFail() } catch {}
        community = BConnectedCommunityEnrollmentCoordinator(persistence: membership, client: service, enrollment: enrollment)
        XCTAssertTrue(try community.progress().applicationOutcomeUncertain)
        service.error = nil
        do { try await community.apply(name: "Fixture", year: 2000, invitation: challenge); XCTFail() } catch {}
        XCTAssertEqual(service.applications, 1)
        XCTAssertNil(keys.bytes)
    }

    @MainActor
    func testLostIntentRequiresExplicitLaterRetryAndRetainsOriginalMaterial() async throws {
        let keys = MemoryStore(), signal = Sender(), membership = CommunityStore(), service = CommunitySender()
        let enrollment = BConnectedEnrollmentCoordinator(persistence: keys, client: signal)
        var date = Date(timeIntervalSince1970: 1_800_000_000)
        var community = BConnectedCommunityEnrollmentCoordinator(persistence: membership, client: service, enrollment: enrollment, now: { date })
        try await community.apply(name: "Fixture", year: 2000, invitation: challenge)
        service.status = .approved; try await community.refreshApproval()
        service.error = BConnectedEnrollmentError.unavailable
        do { try await community.connectApprovedMembership { self.input() }; XCTFail() } catch {}
        let original = try keys.load()!
        community = BConnectedCommunityEnrollmentCoordinator(persistence: membership, client: service, enrollment: enrollment, now: { date })
        service.error = nil; try await community.refreshApproval()
        do { try await community.connectApprovedMembership(preparation: { XCTFail("Must reuse"); return self.input() }, explicitlyRetryLostIntent: true); XCTFail() } catch {}
        XCTAssertEqual(service.intents, 1)
        date = date.addingTimeInterval(301)
        do { try await community.connectApprovedMembership { XCTFail("Must reuse"); return self.input() }; XCTFail() } catch {}
        XCTAssertEqual(service.intents, 1)
        try await community.connectApprovedMembership(preparation: { XCTFail("Must reuse"); return self.input() }, explicitlyRetryLostIntent: true)
        XCTAssertEqual(service.intents, 2)
        let final = try keys.load()!
        XCTAssertEqual(final.password, original.password)
        XCTAssertEqual(final.registrationRequest, original.registrationRequest)
        XCTAssertEqual(final.attempt, original.attempt)
        XCTAssertEqual(final.originalUserAgent, original.originalUserAgent)
    }

    @MainActor
    func testPersistedIntentReceiptRecoversCrossStoreFailureWithoutNewRequest() async throws {
        let keys = MemoryStore(), signal = Sender(), membership = CommunityStore(), service = CommunitySender()
        let enrollment = BConnectedEnrollmentCoordinator(persistence: keys, client: signal)
        let community = BConnectedCommunityEnrollmentCoordinator(persistence: membership, client: service, enrollment: enrollment)
        try await community.apply(name: "Fixture", year: 2000, invitation: challenge)
        service.status = .approved; try await community.refreshApproval()
        service.beforeIntent = { _ in keys.failCommit = true }
        do { try await community.connectApprovedMembership { self.input() }; XCTFail() } catch {}
        XCTAssertNotNil(try membership.load().binding)
        XCTAssertNil(try keys.load()!.binding)
        keys.failCommit = false
        let resumed = BConnectedCommunityEnrollmentCoordinator(persistence: membership, client: service, enrollment: enrollment)
        try await resumed.connectApprovedMembership { XCTFail("Must recover receipt"); return self.input() }
        XCTAssertEqual(service.intents, 1)
        XCTAssertTrue(try enrollment.progress()!.hasApprovedIntentBinding)
    }

    @MainActor
    func testRevokedApprovalAndWrongMemberStopBindingWithoutErasingSavedKeys() async throws {
        let keys = MemoryStore(), signal = Sender(), membership = CommunityStore(), service = CommunitySender()
        let enrollment = BConnectedEnrollmentCoordinator(persistence: keys, client: signal)
        let community = BConnectedCommunityEnrollmentCoordinator(persistence: membership, client: service, enrollment: enrollment)
        try await community.apply(name: "Fixture", year: 2000, invitation: challenge)
        service.status = .approved; try await community.refreshApproval()
        service.wrongMember = true
        do { try await community.connectApprovedMembership { self.input() }; XCTFail() } catch {}
        XCTAssertNil(try keys.load()!.binding)
        let saved = try keys.load()!.registrationRequest
        service.status = .suspended; service.wrongMember = false; try await community.refreshApproval()
        do { try await community.connectApprovedMembership { XCTFail(); return self.input() }; XCTFail() } catch {}
        XCTAssertEqual(try keys.load()!.registrationRequest, saved)
        XCTAssertEqual(service.intents, 1)
    }

    func testCommunityClientExactRoutesBearerAndStrictNonAuthorizingResponse() async throws {
        let http = CommunityHTTP()
        let client = BConnectedCommunityClient(endpoint: try .init(origin: URL(string: "https://community.example.invalid")!), http: http)
        let member: [String: Any] = ["id": memberId, "fullName": "Fixture", "graduationYear": 2000, "status": "pending"]
        http.response = (try BConnectedEnrollmentWire.encode(["token": challenge, "expiresAt": 1_900_000_000_000, "member": member]), 201)
        let session = try await client.enroll(name: "Fixture", year: 2000, invite: challenge)
        XCTAssertNil(http.requests.last!.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(http.requests.last!.url?.path, "/v1/enroll")
        http.response = (try BConnectedEnrollmentWire.encode(member), 200)
        _ = try await client.member(token: session.token)
        XCTAssertEqual(http.requests.last!.httpMethod, "GET")
        XCTAssertEqual(http.requests.last!.value(forHTTPHeaderField: "Authorization"), "Bearer " + challenge)
        let material = BConnectedEnrollmentIntentMaterial(registrationAttemptId: challenge, keyCommitment: String(repeating: "a", count: 64))
        var intent: [String: Any] = ["memberId": memberId, "bindingChallenge": challenge, "expiresAt": 1_900_000_000_000,
                                  "status": "awaiting_signal_claim", "registrationAuthorized": false]
        http.response = (try BConnectedEnrollmentWire.encode(intent), 201)
        _ = try await client.intent(token: session.token, material: material)
        let body = try BConnectedEnrollmentWire.object(http.requests.last!.httpBody!)
        XCTAssertEqual(Set(body.keys), ["registrationAttemptId", "deviceKeyCommitment"])
        XCTAssertEqual(http.requests.last!.url?.path, "/v1/admission/intents")
        intent["registrationAuthorized"] = true; http.response = (try BConnectedEnrollmentWire.encode(intent), 201)
        do { _ = try await client.intent(token: session.token, material: material); XCTFail() } catch {}
        http.response = (Data("{\"error\":\"private IAM detail\"}".utf8), 401)
        do { _ = try await client.member(token: session.token); XCTFail() }
        catch { XCTAssertEqual(error as? BConnectedEnrollmentError, .unavailable) }
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
    var supportsNativeInstallation = false
    var failInstall = false
    var installCount = 0
    var failPublicationAcknowledgement = false
    func preparePublication(configuration: BConnectedPublicationConfiguration) throws -> BConnectedEnrollmentRecord {
        try transaction { record in
            guard var value = record, let entropy = value.accountEntropyReceipt, value.observation?.state == .active else { throw BConnectedEnrollmentError.immutableConflict }
            if let existing = value.publication {
                guard existing.configurationHash == configuration.hash else { throw BConnectedEnrollmentError.immutableConflict }
            } else {
                let attributes = try BConnectedEnrollmentWire.encode(BConnectedEnrollmentWire.object(value.registrationRequest)["accountAttributes"] as! [String: Any])
                let key = try ProfileKey(contents: Data(repeating: 1, count: 32))
                let aci = Aci(fromUUID: UUID(uuidString: value.installedAccount!.aci)!)
                let profile = try BConnectedEnrollmentWire.encode(["avatar": true, "sameAvatar": true, "badgeIds": [String](),
                    "version": String(repeating: "a", count: 64),
                    "commitment": try key.getCommitment(userId: aci).serialize().base64EncodedString(),
                    "phoneNumberSharing": Data(repeating: 1, count: 29).base64EncodedString()])
                value.publication = .init(version: 1, configurationHash: configuration.hash, entropyReceipt: entropy,
                    profileStateHash: Data(repeating: 1, count: 32), accountAttributes: attributes, encryptedProfile: profile,
                    payloadHash: BConnectedEnrollmentRecord.Publication.hash(attributes: attributes, profile: profile))
            }
            record = value; return value
        }
    }
    func transitionPublication(expected: BConnectedEnrollmentRecord, step: BConnectedPublicationStep, acknowledge: Bool) throws -> BConnectedEnrollmentRecord {
        if acknowledge && failPublicationAcknowledgement { throw BConnectedEnrollmentError.persistenceUnavailable }
        return try transaction { record in
            guard var value = record, var publication = value.publication, publication == expected.publication else { throw BConnectedEnrollmentError.immutableConflict }
            if step == .attributes { publication.attributesState = acknowledge ? .acknowledged : .dispatched }
            else { publication.profileState = acknowledge ? .acknowledged : .dispatched }
            value.publication = publication; record = value; return value
        }
    }
    func prepareAccountEntropy() throws {
        try transaction { record in
            guard var value = record, let local = value.localSetupReceipt else { throw BConnectedEnrollmentError.immutableConflict }
            if value.accountEntropyReceipt != nil { return }
            value.accountEntropyReceipt = .init(version: 1, localSetup: local, entropyHash: Data(repeating: 1, count: 32))
            record = value
        }
    }
    func prepareLocalAccount() throws {
        try transaction { record in
            guard var value = record, let account = value.installedAccount else { throw BConnectedEnrollmentError.immutableConflict }
            if value.localSetupReceipt != nil { return }
            value.localSetupReceipt = .init(version: 1, attempt: value.attempt, keyCommitment: value.keyCommitment,
                account: account, profileUniqueId: "profile-fixture", profileAccessKeyHash: try value.profileAccessKeyHash(),
                recipientId: 1, recipientUniqueId: "recipient-fixture")
            record = value
        }
    }
    func installNativeAccount(expected: BConnectedEnrollmentRecord, account: BConnectedEnrollmentObservation.Account) throws {
        if failInstall { throw BConnectedEnrollmentError.persistenceUnavailable }
        let fresh = try transaction { record in
            guard var value = record, value.attempt == expected.attempt, value.observation?.account == account,
                  value.installedAccount == nil || value.installedAccount == account else { throw BConnectedEnrollmentError.immutableConflict }
            let fresh = value.installedAccount == nil
            value.installedAccount = account; record = value
            return fresh
        }
        if fresh { installCount += 1 }
    }
    func load() throws -> BConnectedEnrollmentRecord? { try bytes.map { try JSONDecoder().decode(BConnectedEnrollmentRecord.self, from: $0) } }
    func transaction<T>(_ update: (inout BConnectedEnrollmentRecord?) throws -> T) throws -> T {
        var record = try load(); try record?.validate()
        let result = try update(&record)
        if failCommit { throw BConnectedEnrollmentError.persistenceUnavailable }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        bytes = try record.map { try encoder.encode($0) }
        return result
    }
}

private final class PublicationSender: BConnectedPublicationSending {
    var steps: [BConnectedPublicationStep] = []
    var bodies: [Data] = []
    var failStep: BConnectedPublicationStep?
    var beforeSend: ((BConnectedPublicationStep, BConnectedEnrollmentRecord) throws -> Void)?
    func send(_ step: BConnectedPublicationStep, record: BConnectedEnrollmentRecord, configuration: BConnectedPublicationConfiguration) async throws {
        try beforeSend?(step, record)
        steps.append(step)
        bodies.append(step == .attributes ? record.publication!.accountAttributes : record.publication!.encryptedProfile)
        if step == failStep { throw CancellationError() }
    }
}

private final class PublicationHTTP: BConnectedOwnedHTTPSending {
    var result = (Data(), 204)
    var lastRequest: URLRequest?
    func send(_ request: URLRequest) async throws -> (Data, Int) { lastRequest = request; return result }
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

private final class CommunityStore: BConnectedCommunityPersistence {
    var bytes: Data?
    var failCommit = false
    func load() throws -> BConnectedCommunityRecord {
        if let bytes { return try JSONDecoder().decode(BConnectedCommunityRecord.self, from: bytes) }
        return .init()
    }
    func transaction<T>(_ update: (inout BConnectedCommunityRecord) throws -> T) throws -> T {
        var record = try load(); try record.validate()
        let result = try update(&record)
        guard !failCommit else { throw BConnectedEnrollmentError.persistenceUnavailable }
        try record.validate(); bytes = try JSONEncoder().encode(record)
        return result
    }
}
private final class CommunitySender: BConnectedCommunitySending {
    var status: BConnectedCommunityMember.Status = .pending
    var error: Error?
    var applications = 0
    var intents = 0
    var wrongMember = false
    var beforeIntent: ((BConnectedEnrollmentIntentMaterial) throws -> Void)?
    let id = "00000000-0000-4000-8000-000000000001"
    let challenge = "ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8"
    func enroll(name: String, year: Int, invite: String) async throws -> BConnectedCommunityRecord.Session {
        applications += 1; if let error { throw error }
        return .init(token: challenge, expiresAt: 1_900_000_000_000, member: .init(id: id, fullName: name, graduationYear: year, status: .pending))
    }
    func member(token: String) async throws -> BConnectedCommunityMember {
        if let error { throw error }
        return .init(id: id, fullName: "Fixture", graduationYear: 2000, status: status)
    }
    func intent(token: String, material: BConnectedEnrollmentIntentMaterial) async throws -> BConnectedCommunityRecord.Binding {
        intents += 1; try beforeIntent?(material); if let error { throw error }
        return .init(memberId: wrongMember ? "00000000-0000-4000-8000-000000000002" : id, bindingChallenge: challenge, expiresAt: 1_900_000_000_000)
    }
}
private final class CommunityHTTP: BConnectedOwnedHTTPSending {
    var response = (Data(), 200)
    var requests: [URLRequest] = []
    func send(_ request: URLRequest) async throws -> (Data, Int) { requests.append(request); return response }
}
