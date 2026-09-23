// Copyright 2026 BConnected contributors. SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import XCTest
import LibSignalClient
import CryptoKit
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
        let configuration = try BConnectedPublicationConfiguration(origin: URL(string: "https://publication.example.invalid")!, authorityCommitment: Data(repeating: 1, count: 32))
        let coordinator = BConnectedEnrollmentCoordinator(persistence: store, client: sender, publicationConfiguration: configuration, publisher: publisher)
        _ = try coordinator.prepare(input()); try coordinator.bindApprovedIntent(memberId: memberId, challenge: challenge)
        sender.result = try observation("active"); _ = try await coordinator.perform(.begin)
        try await coordinator.installNativeAccount(); try coordinator.prepareLocalAccount(); try coordinator.prepareAccountEntropy()
        sender.calls = []
        return (store, sender, publisher, coordinator)
    }

    @MainActor
    private func preKeyFixture() async throws -> (MemoryStore, Sender, PreKeySender, BConnectedEnrollmentCoordinator, BConnectedPublicationConfiguration) {
        let (store, sender, _, initial) = try await publicationFixture()
        try await initial.publishAccount()
        let configuration = try BConnectedPublicationConfiguration(origin: URL(string: "https://publication.example.invalid")!, authorityCommitment: Data(repeating: 1, count: 32))
        let publisher = PreKeySender()
        let coordinator = BConnectedEnrollmentCoordinator(persistence: store, client: sender, publicationConfiguration: configuration, preKeyPublisher: publisher)
        return (store, sender, publisher, coordinator, configuration)
    }

    @MainActor
    private func acceptanceFixture() async throws -> (MemoryStore, Sender, AcceptanceReader, BConnectedEnrollmentCoordinator, BConnectedPublicationConfiguration) {
        let (store, sender, _, initial, configuration) = try await preKeyFixture()
        try await initial.publishPreKeys()
        sender.calls = []
        let reader = AcceptanceReader()
        let coordinator = BConnectedEnrollmentCoordinator(persistence: store, client: sender,
            publicationConfiguration: configuration, acceptanceReader: reader)
        return (store, sender, reader, coordinator, configuration)
    }

    @MainActor
    func testAccountAcceptanceAlwaysFreshNeverWritesAnAcceptanceOrResendsKeys() async throws {
        let (store, sender, reader, coordinator, configuration) = try await acceptanceFixture()
        let original = store.bytes
        try await coordinator.verifyPublishedAccount()
        XCTAssertEqual(sender.calls, [.status]); XCTAssertEqual(reader.steps, [.identity, .profile])
        XCTAssertEqual(store.bytes, original)
        let reopened = MemoryStore(); reopened.bytes = original; reopened.supportsNativeInstallation = true
        let next = BConnectedEnrollmentCoordinator(persistence: reopened, client: sender, publicationConfiguration: configuration, acceptanceReader: reader)
        try await next.verifyPublishedAccount()
        XCTAssertEqual(sender.calls, [.status, .status]); XCTAssertEqual(reader.steps, [.identity, .profile, .identity, .profile])
        XCTAssertEqual(reopened.bytes, original)
    }

    @MainActor
    func testAccountAcceptanceRechecksOriginalContextAcrossStatusAndEveryRead() async throws {
        for boundary in 0...2 {
            let (store, sender, reader, coordinator, _) = try await acceptanceFixture()
            let change = { try store.transaction { $0!.sendNeedsExplicitDecision.toggle() } }
            if boundary == 0 { sender.beforeReturn = { try! change() } }
            else { reader.beforeReturn = { step in if (boundary == 1 && step == .identity) || (boundary == 2 && step == .profile) { try change() } } }
            do { try await coordinator.verifyPublishedAccount(); XCTFail("changed original context accepted") } catch {}
            XCTAssertEqual(reader.steps.count, boundary)
        }
    }

    @MainActor
    func testAccountAcceptanceRejectsIncompleteLegacyAndChangedConfigurationBeforeRequests() async throws {
        for mutation in 0...3 {
            let (store, sender, reader, coordinator, _) = try await acceptanceFixture()
            try store.transaction { value in
                switch mutation {
                case 0: value!.preKeyPublication!.pni.state = .dispatched
                case 1:
                    let keys = value!.preKeyPublication!
                    value!.preKeyPublication = .init(version: 1, route: nil, contextHash: try value!.preKeyContextHash(), aci: keys.aci, pni: keys.pni)
                case 2: value!.observation = try observation("suspended")
                default: value!.preKeyPublication = nil
                }
            }
            do { try await coordinator.verifyPublishedAccount(); XCTFail() } catch {}
            XCTAssertTrue(sender.calls.isEmpty); XCTAssertTrue(reader.steps.isEmpty)
        }
        let (store, sender, reader, _, configuration) = try await acceptanceFixture()
        let other = try BConnectedPublicationConfiguration(origin: configuration.origin, authorityCommitment: Data(repeating: 2, count: 32))
        let coordinator = BConnectedEnrollmentCoordinator(persistence: store, client: sender, publicationConfiguration: other, acceptanceReader: reader)
        do { try await coordinator.verifyPublishedAccount(); XCTFail() } catch {}
        XCTAssertTrue(sender.calls.isEmpty); XCTAssertTrue(reader.steps.isEmpty)
    }

    @MainActor
    func testAccountAcceptanceSuspensionLossAndLocalFailureDoNotContinueOrCacheSuccess() async throws {
        let (store, sender, reader, coordinator, _) = try await acceptanceFixture()
        let original = store.bytes
        sender.result = try observation("suspended")
        do { try await coordinator.verifyPublishedAccount(); XCTFail() } catch {}
        XCTAssertTrue(reader.steps.isEmpty)
        store.bytes = original; sender.result = try observation("active")
        reader.beforeReturn = { _ in throw BConnectedEnrollmentError.unavailable }
        do { try await coordinator.verifyPublishedAccount(); XCTFail() } catch {}
        XCTAssertEqual(reader.steps, [.identity]); XCTAssertEqual(store.bytes, original)
        reader.steps = []; reader.beforeReturn = { _ in store.failAcceptanceValidation = true }
        do { try await coordinator.verifyPublishedAccount(); XCTFail() } catch {}
        XCTAssertEqual(reader.steps, [.identity]); XCTAssertEqual(store.bytes, original)
        store.failAcceptanceValidation = false; reader.steps = []; reader.beforeReturn = nil
        try await coordinator.verifyPublishedAccount()
        XCTAssertEqual(reader.steps, [.identity, .profile]); XCTAssertEqual(store.bytes, original)
    }

    private func acceptanceResponse(_ step: BConnectedAccountAcceptanceStep, record: BConnectedEnrollmentRecord) throws -> [String: Any] {
        let account = record.installedAccount!
        if step == .identity {
            return ["uuid": account.aci, "pni": account.pni, "number": account.number, "storageCapable": false,
                    "entitlements": ["badges": [Any]()], "usernameHash": NSNull(), "usernameLinkHandle": NSNull(), "authCredentialSalt": NSNull()]
        }
        let original = try BConnectedEnrollmentWire.object(record.registrationRequest)
        let attrs = original["accountAttributes"] as! [String: Any]
        let uak = try BConnectedEnrollmentWire.base64(attrs["unidentifiedAccessKey"])
        var response: [String: Any] = ["uuid": account.aci, "identityKey": original["aciIdentityKey"]!,
            "unidentifiedAccess": Data(HMAC<SHA256>.authenticationCode(for: Data(repeating: 0, count: 32), using: SymmetricKey(data: uak))).base64EncodedString(),
            "unrestrictedUnidentifiedAccess": false, "capabilities": ["attachmentBackfill": false, "spqr": true, "profiles_v2": false, "usernameChangeSyncMessage": false],
            "badges": [Any](), "avatar": NSNull(), "paymentAddress": NSNull()]
        let profile = try BConnectedEnrollmentWire.object(record.publication!.encryptedProfile)
        for key in ["name", "about", "aboutEmoji", "phoneNumberSharing"] { response[key] = profile[key] ?? NSNull() }
        return response
    }

    @MainActor
    private func acceptanceRecordBytes() async throws -> Data {
        let (store, _, _, _, _) = try await acceptanceFixture()
        return try XCTUnwrap(store.bytes)
    }

    func testAccountAcceptanceExactOwnedGetRoutesCredentialsAndStrictResponses() async throws {
        let record = try JSONDecoder().decode(BConnectedEnrollmentRecord.self, from: await acceptanceRecordBytes())
        let configuration = try BConnectedPublicationConfiguration(origin: URL(string: "https://publication.example.invalid")!, authorityCommitment: Data(repeating: 1, count: 32))
        let http = PublicationHTTP()
        let client = BConnectedAccountAcceptanceClient(http: http)
        for step in BConnectedAccountAcceptanceStep.allCases {
            let good = try acceptanceResponse(step, record: record)
            http.result = (try BConnectedEnrollmentWire.encode(good), 200)
            try await client.read(step, record: record, configuration: configuration)
            let request = http.lastRequest!
            XCTAssertEqual(request.httpMethod, "GET"); XCTAssertNil(request.httpBody)
            XCTAssertEqual(request.url?.host, "publication.example.invalid"); XCTAssertEqual(request.url?.port, nil)
            XCTAssertNil(request.url?.query)
            let profile = try BConnectedEnrollmentWire.object(record.publication!.encryptedProfile)
            XCTAssertEqual(request.url?.path, step == .identity ? "/v1/accounts/whoami" : "/v1/profile/\(record.installedAccount!.aci)/\(profile["version"]!)")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic " + Data((record.installedAccount!.aci + ":" + record.password).utf8).base64EncodedString())
            var changes: [(String, Any?)] = [("uuid", memberId), ("uuid", nil), ("unknown", true)]
            if step == .identity { changes += [("number", "+13055550000"), ("pni", memberId), ("storageCapable", 0), ("storageCapable", true), ("usernameHash", "changed"), ("usernameLinkHandle", memberId), ("authCredentialSalt", "changed"), ("entitlements", false)] }
            else { changes += [("identityKey", try record.pni.publicFields(prefix: "pni")["pniIdentityKey"]!), ("unidentifiedAccess", Data(repeating: 0, count: 32).base64EncodedString()), ("unrestrictedUnidentifiedAccess", true), ("phoneNumberSharing", Data(repeating: 2, count: 29).base64EncodedString()), ("phoneNumberSharing", nil), ("name", "wrong"), ("avatar", "untrusted/avatar"), ("paymentAddress", "changed"), ("badges", ["unexpected"]), ("capabilities", ["spqr": true]), ("capabilities", ["attachmentBackfill": false, "spqr": true, "profiles_v2": 0, "usernameChangeSyncMessage": false])] }
            for (field, value) in changes {
                var bad = good; bad[field] = value
                http.result = (try BConnectedEnrollmentWire.encode(bad), 200)
                do { try await client.read(step, record: record, configuration: configuration); XCTFail("accepted \(field)") } catch {}
            }
            for status in [204, 304, 401, 404, 500] {
                http.result = (try BConnectedEnrollmentWire.encode(good), status)
                do { try await client.read(step, record: record, configuration: configuration); XCTFail() } catch {}
            }
            for data in [Data("{\"uuid\":\"a\",\"u\\u0075id\":\"b\"}".utf8), Data(repeating: 32, count: 65_537), Data([0xff]), Data("[]".utf8)] {
                http.result = (data, 200)
                do { try await client.read(step, record: record, configuration: configuration); XCTFail() } catch {}
            }
        }
    }

    func testAccountAcceptanceTransportRequiresJSONAndDoesNotRequireEnrollmentCacheHeader() async throws {
        EnrollmentURLProtocol.status = 200; EnrollmentURLProtocol.noStore = false; EnrollmentURLProtocol.redirect = false
        EnrollmentURLProtocol.responseBody = Data("{}".utf8)
        let http = BConnectedOwnedHTTP(protocolClasses: [EnrollmentURLProtocol.self], responseMode: .accountJSON)
        let request = URLRequest(url: URL(string: "https://publication.example.invalid/v1/accounts/whoami")!)
        defer { EnrollmentURLProtocol.noStore = true; EnrollmentURLProtocol.contentType = "application/json" }
        _ = try await http.send(request)
        for type in ["text/html", "application/octet-stream"] {
            EnrollmentURLProtocol.contentType = type
            do { _ = try await http.send(request); XCTFail() } catch {}
        }
    }

    func testActualJavaAccountAndProfileSerializationMatchesPublicWireInputs() throws {
        let fixture = try BConnectedEnrollmentWire.object(resource("bconnected-account-acceptance-v1"))
        let input = try XCTUnwrap(fixture["input"] as? [String: Any])
        let account = BConnectedEnrollmentObservation.Account(aci: try BConnectedEnrollmentWire.uuid(input["aci"]),
            pni: try BConnectedEnrollmentWire.uuid(input["pni"]), number: try BConnectedEnrollmentWire.text(input["number"]), deviceId: 1)
        let attributes = try BConnectedEnrollmentWire.encode(XCTUnwrap(input["accountAttributes"] as? [String: Any]))
        let profile = try BConnectedEnrollmentWire.encode(XCTUnwrap(input["encryptedProfile"] as? [String: Any]))
        let identity = try BConnectedEnrollmentWire.base64(input["aciIdentityKey"])
        for (step, field) in [(BConnectedAccountAcceptanceStep.identity, "whoamiBase64"), (.profile, "profileBase64")] {
            try BConnectedAccountAcceptanceClient.validateResponse(BConnectedEnrollmentWire.base64(fixture[field]), status: 200,
                step: step, account: account, attributes: attributes, profile: profile, identityKey: identity)
        }
    }

    @MainActor
    func testPreKeysDispatchPersistedOncePerIdentityAndAcknowledgedReentryNeverSends() async throws {
        let (store, _, publisher, coordinator, configuration) = try await preKeyFixture()
        let draft = try store.preparePreKeys(configuration: configuration)
        publisher.beforeSend = { identity, record in
            XCTAssertEqual(try store.load()?.preKeyPublication, record.preKeyPublication)
            XCTAssertEqual(record.preKeyPublication?.batch(identity).state, .dispatched)
        }
        try await coordinator.publishPreKeys()
        XCTAssertEqual(publisher.identities, [.aci, .pni])
        XCTAssertEqual(publisher.bodies, [draft.preKeyPublication!.aci.request, draft.preKeyPublication!.pni.request])
        XCTAssertTrue(try XCTUnwrap(coordinator.progress()).preKeyPublicationComplete)
        let completed = try store.load()!.preKeyPublication
        try await coordinator.publishPreKeys()
        XCTAssertEqual(publisher.identities.count, 2)
        XCTAssertEqual(try store.load()?.preKeyPublication, completed)
    }

    @MainActor
    func testOwnedPreKeysUncertainResponseAndFailedAcknowledgementReplayOriginalOperationAfterRestart() async throws {
        for failAck in [false, true] {
            let (store, sender, publisher, coordinator, configuration) = try await preKeyFixture()
            publisher.fail = !failAck; store.failPreKeyAcknowledgement = failAck
            do { try await coordinator.publishPreKeys(); XCTFail() } catch {}
            let saved = try XCTUnwrap(store.load()?.preKeyPublication)
            XCTAssertEqual(saved.aci.state, .dispatched); XCTAssertEqual(saved.pni.state, .prepared)
            XCTAssertEqual(publisher.identities, [.aci])
            let reopened = MemoryStore(); reopened.bytes = store.bytes; reopened.supportsNativeInstallation = true
            let nextSender = PreKeySender()
            nextSender.beforeSend = { identity, record in
                XCTAssertEqual(record.preKeyPublication?.route, saved.route)
                XCTAssertEqual(record.preKeyPublication?.batch(identity).request, saved.batch(identity).request)
                XCTAssertEqual(record.preKeyPublication?.batch(identity).ec, saved.batch(identity).ec)
                XCTAssertEqual(record.preKeyPublication?.batch(identity).pq, saved.batch(identity).pq)
            }
            let restarted = BConnectedEnrollmentCoordinator(persistence: reopened, client: sender, publicationConfiguration: configuration, preKeyPublisher: nextSender)
            XCTAssertTrue(try XCTUnwrap(restarted.progress()).preKeyPublicationUncertain)
            XCTAssertFalse(try XCTUnwrap(restarted.progress()).preKeyPublicationBlocked)
            sender.calls = []
            try await restarted.publishPreKeys()
            XCTAssertEqual(sender.calls, [.status])
            XCTAssertEqual(nextSender.identities, [.aci, .pni])
            XCTAssertTrue(try XCTUnwrap(restarted.progress()).preKeyPublicationComplete)
        }
    }

    @MainActor
    func testOwnedPreKeyRestartReplaysOnlyUnacknowledgedPNI() async throws {
        let (store, sender, publisher, coordinator, configuration) = try await preKeyFixture()
        publisher.beforeSend = { identity, _ in publisher.fail = identity == .pni }
        do { try await coordinator.publishPreKeys(); XCTFail() } catch {}
        publisher.beforeSend = nil
        let saved = try XCTUnwrap(store.load()?.preKeyPublication)
        XCTAssertEqual(saved.aci.state, .acknowledged); XCTAssertEqual(saved.pni.state, .dispatched)
        let reopened = MemoryStore(); reopened.bytes = store.bytes; reopened.supportsNativeInstallation = true
        let next = PreKeySender()
        next.beforeSend = { identity, record in
            XCTAssertEqual(identity, .pni)
            XCTAssertEqual(record.preKeyPublication?.route, saved.route)
        }
        let restarted = BConnectedEnrollmentCoordinator(persistence: reopened, client: sender, publicationConfiguration: configuration, preKeyPublisher: next)
        try await restarted.publishPreKeys()
        XCTAssertEqual(next.identities, [.pni]); XCTAssertEqual(next.bodies, [saved.pni.request])
        XCTAssertTrue(try XCTUnwrap(restarted.progress()).preKeyPublicationComplete)
    }

    @MainActor
    func testLegacyPreparedAndUncertainPreKeysNeverMigrateOrSend() async throws {
        for state in [BConnectedEnrollmentRecord.Publication.State.prepared, .dispatched] {
            let (store, sender, publisher, _, configuration) = try await preKeyFixture()
            var record = try store.preparePreKeys(configuration: configuration)
            let modern = record.preKeyPublication!
            record.preKeyPublication = .init(version: 1, route: nil, contextHash: try record.preKeyContextHash(), aci: modern.aci, pni: modern.pni)
            record.preKeyPublication?.aci.state = state
            store.bytes = try JSONEncoder().encode(record)
            // Decodes the old shape with absent optional route; a new process preserves it.
            let reopened = MemoryStore(); reopened.bytes = store.bytes; reopened.supportsNativeInstallation = true
            let restarted = BConnectedEnrollmentCoordinator(persistence: reopened, client: sender, publicationConfiguration: configuration, preKeyPublisher: publisher)
            do { try await restarted.publishPreKeys(); XCTFail() }
            catch { XCTAssertEqual(error as? BConnectedEnrollmentError, .uncertainPreKeyPublication) }
            XCTAssertTrue(publisher.identities.isEmpty)
            XCTAssertEqual(try reopened.load()?.preKeyPublication, record.preKeyPublication)
            XCTAssertTrue(try XCTUnwrap(restarted.progress()).preKeyPublicationBlocked)
            var dispatched = record; dispatched.preKeyPublication?.aci.state = .dispatched
            XCTAssertThrowsError(try BConnectedPreKeyClient().request(.aci, record: dispatched, configuration: configuration))
        }
    }

    func testOwnedPreKeyContractOriginAndOperationIdentityCannotChange() async throws {
        let bytes = try await preKeyRecordBytes()
        let original = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        for (field, value) in [("contract", "other"), ("origin", "https://other.example.invalid"),
                               ("pathPrefix", "/v2/keys/"), ("aciOperationId", UUID().uuidString.lowercased()),
                               ("pniOperationId", "../invalid")] {
            var changed = original
            var keys = changed["preKeyPublication"] as! [String: Any]
            var route = keys["route"] as! [String: Any]
            route[field] = value; keys["route"] = route; changed["preKeyPublication"] = keys
            let record = try JSONDecoder().decode(BConnectedEnrollmentRecord.self, from: JSONSerialization.data(withJSONObject: changed))
            XCTAssertThrowsError(try record.validate())
        }
    }

    @MainActor
    func testPreKeysOriginalBindingAuthorityAndSuspensionRejectBeforeAnySend() async throws {
        let (store, sender, publisher, coordinator, configuration) = try await preKeyFixture()
        _ = try store.preparePreKeys(configuration: configuration)
        let saved = try XCTUnwrap(store.load())
        var changed = saved
        changed.binding = .init(memberId: "00000000-0000-4000-8000-000000000002", challenge: challenge)
        XCTAssertThrowsError(try changed.validate())
        let different = try BConnectedPublicationConfiguration(origin: configuration.origin, authorityCommitment: Data(repeating: 2, count: 32))
        XCTAssertThrowsError(try store.preparePreKeys(configuration: different))
        sender.result = try observation("suspended")
        do { try await coordinator.publishPreKeys(); XCTFail() } catch {}
        XCTAssertTrue(publisher.identities.isEmpty)
        XCTAssertEqual(try store.load()?.preKeyPublication, saved.preKeyPublication)
    }

    func testPreKeyLedgerRejectsForeignSignatureDuplicateIdsAndChangedPublicBytes() async throws {
        let original = try JSONDecoder().decode(BConnectedEnrollmentRecord.self, from: await preKeyRecordBytes())
        let batch = original.preKeyPublication!.aci
        var foreign = batch.pq; foreign[0] = original.preKeyPublication!.pni.pq[0]
        XCTAssertThrowsError(try BConnectedEnrollmentRecord.PreKeyPublication.Batch.request(ec: batch.ec, pq: foreign, identity: original.aci))
        var duplicate = batch.ec; duplicate[1] = duplicate[0]
        XCTAssertThrowsError(try BConnectedEnrollmentRecord.PreKeyPublication.Batch.request(ec: duplicate, pq: batch.pq, identity: original.aci))
        XCTAssertThrowsError(try BConnectedEnrollmentRecord.PreKeyPublication.Batch.request(ec: Array(batch.ec.dropLast()), pq: batch.pq, identity: original.aci))
        var changed = original
        changed.preKeyPublication?.aci = .init(ec: batch.ec, pq: batch.pq, request: batch.request + Data([32]))
        XCTAssertThrowsError(try changed.validate())
    }

    @MainActor
    private func preKeyRecordBytes() async throws -> Data {
        let (store, _, _, _, configuration) = try await preKeyFixture()
        return try JSONEncoder().encode(store.preparePreKeys(configuration: configuration))
    }

    func testPreKeyClientFrozenPublicOnlyACIAndPNIRoutesAndStrictEmpty204() async throws {
        var record = try JSONDecoder().decode(BConnectedEnrollmentRecord.self, from: await preKeyRecordBytes())
        let configuration = try BConnectedPublicationConfiguration(origin: URL(string: "https://publication.example.invalid")!, authorityCommitment: Data(repeating: 1, count: 32))
        let http = PublicationHTTP(), client = BConnectedPreKeyClient(http: http)
        for identity in [BConnectedPreKeyIdentity.aci, .pni] {
            if identity == .aci { record.preKeyPublication?.aci.state = .dispatched }
            else { record.preKeyPublication?.aci.state = .acknowledged; record.preKeyPublication?.pni.state = .dispatched }
            let request = try client.request(identity, record: record, configuration: configuration)
            let route = try XCTUnwrap(record.preKeyPublication?.route)
            XCTAssertEqual(request.url?.absoluteString, "https://publication.example.invalid/v1/bconnected/keys/initial/" + route.operationId(identity) + "?identity=" + identity.rawValue)
            XCTAssertNotEqual(route.aciOperationId, route.pniOperationId)
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(request.httpBody, record.preKeyPublication?.batch(identity).request)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic " + Data((record.installedAccount!.aci.lowercased() + ":" + record.password).utf8).base64EncodedString())
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
            XCTAssertEqual(Set(body.keys), ["preKeys", "pqPreKeys"])
            XCTAssertEqual((body["preKeys"] as? [[String: Any]])?.count, 100)
            XCTAssertEqual((body["pqPreKeys"] as? [[String: Any]])?.count, 100)
            http.result = (Data(), 204); try await client.send(identity, record: record, configuration: configuration)
            for invalid in [(Data(), 200), (Data("{}".utf8), 204), (Data(), 302), (Data(), 400), (Data(), 401), (Data(), 404), (Data(), 409), (Data(), 503)] {
                http.result = invalid
                do { try await client.send(identity, record: record, configuration: configuration); XCTFail() } catch {}
            }
        }
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
        for string in ["http://example.invalid", "https://u:p@example.invalid", "https://example.invalid/path", "https://example.invalid?q=1", "https://example.invalid#f", "https://example.invalid:8443", "https://127.0.0.1", "https://2130706433", "https://0x7f000001", "https://example.invalid.", "https://exa%mple.invalid", "https://%65xample.invalid", "https://exa%6dple.invalid", "https://éxample.invalid", "https://xn--xample-9ua.invalid", "https://[::1]", "https://chat.signal.org", "https://signal.org", "https://cdn.whispersystems.org", "https://-a.invalid", "https://a..invalid"] {
            guard let url = URL(string: string) else { continue } // Foundation itself rejects some malformed URL spellings.
            XCTAssertThrowsError(try BConnectedPublicationConfiguration(origin: url, authorityCommitment: Data(repeating: 1, count: 32)))
        }
        let one = try BConnectedPublicationConfiguration(origin: URL(string: "https://example.invalid:443/")!, authorityCommitment: Data(repeating: 1, count: 32))
        let two = try BConnectedPublicationConfiguration(origin: URL(string: "https://example.invalid")!, authorityCommitment: Data(repeating: 1, count: 32))
        let mixedCase = try BConnectedPublicationConfiguration(origin: URL(string: "https://ExAmPlE.InVaLiD:443/")!, authorityCommitment: Data(repeating: 1, count: 32))
        XCTAssertEqual(one.origin.absoluteString, "https://example.invalid")
        XCTAssertEqual(mixedCase.origin.absoluteString, "https://example.invalid")
        XCTAssertEqual(one.hash, two.hash)
        XCTAssertEqual(one.hash, mixedCase.hash)
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
        let config = try BConnectedPublicationConfiguration(origin: URL(string: "https://publication.example.invalid")!, authorityCommitment: Data(repeating: 1, count: 32))
        let http = PublicationHTTP(), client = BConnectedPublicationClient(http: http)
        let request = try client.request(.attributes, record: record, configuration: config)
        XCTAssertEqual(request.url?.absoluteString, "https://publication.example.invalid/v1/accounts/attributes/")
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
        let config = try BConnectedPublicationConfiguration(origin: URL(string: "https://publication.example.invalid")!, authorityCommitment: Data(repeating: 1, count: 32))
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
        let client = BConnectedEnrollmentClient(endpoint: try .init(origin: URL(string: "https://enrollment.example.invalid")!))
        let request = try client.request(.checkCode, record: record, code: "12345")
        XCTAssertEqual(request.url?.absoluteString, "https://enrollment.example.invalid/v1/bconnected/enrollment/\(operationId)/check-code")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic " + Data((phone + ":" + record.password).utf8).base64EncodedString())
        let body = String(decoding: request.httpBody!, as: UTF8.self)
        for secret in [record.password, record.aci.pair.base64EncodedString(), record.pni.signedPreKey.base64EncodedString()] { XCTAssertFalse(body.contains(secret)) }
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        for url in ["https://enrollment.example.invalid:8443", "https://127.0.0.1", "https://2130706433", "https://0x7f000001", "http://enrollment.example.invalid", "https://u:p@example.invalid", "https://example.invalid/chat", "https://example.invalid?q=1", "https://example.invalid#secret"] {
            XCTAssertThrowsError(try BConnectedEnrollmentEndpoint(origin: URL(string: url)!))
        }
    }
}

private final class MemoryStore: BConnectedEnrollmentPersistence {
    var failAcceptanceValidation = false
    func validateAccountAcceptance(configuration: BConnectedPublicationConfiguration, expected: BConnectedEnrollmentRecord?) throws -> BConnectedEnrollmentRecord {
        if failAcceptanceValidation { throw BConnectedEnrollmentError.persistenceUnavailable }
        return try transaction { value in
            guard let value else { throw BConnectedEnrollmentError.missingAttempt }
            try value.validateAccountAcceptance(configuration: configuration, expected: expected)
            return value
        }
    }
    var bytes: Data?
    var failCommit = false
    var supportsNativeInstallation = false
    var failInstall = false
    var installCount = 0
    var failPreKeyAcknowledgement = false
    func preparePreKeys(configuration: BConnectedPublicationConfiguration) throws -> BConnectedEnrollmentRecord {
        _ = try preparePublication(configuration: configuration)
        return try transaction { record in
            guard var value = record, value.publication?.complete == true else { throw BConnectedEnrollmentError.immutableConflict }
            if value.preKeyPublication == nil {
                let route = BConnectedEnrollmentRecord.PreKeyPublication.Route.generate(configuration: configuration)
                value.preKeyPublication = .init(version: 2, route: route, contextHash: try value.preKeyContextHash(route: route),
                    aci: try testPreKeyBatch(value.aci), pni: try testPreKeyBatch(value.pni))
            }
            record = value; return value
        }
    }
    func transitionPreKeys(expected: BConnectedEnrollmentRecord, identity: BConnectedPreKeyIdentity, acknowledge: Bool) throws -> BConnectedEnrollmentRecord {
        if acknowledge && failPreKeyAcknowledgement { throw BConnectedEnrollmentError.persistenceUnavailable }
        return try transaction { record in
            guard var value = record, var keys = value.preKeyPublication, keys == expected.preKeyPublication,
                  keys.version == 2,
                  keys.batch(identity).state == (acknowledge ? .dispatched : .prepared) || (!acknowledge && keys.batch(identity).state == .dispatched) else { throw BConnectedEnrollmentError.immutableConflict }
            if identity == .aci { keys.aci.state = acknowledge ? .acknowledged : .dispatched }
            else { keys.pni.state = acknowledge ? .acknowledged : .dispatched }
            value.preKeyPublication = keys; record = value; return value
        }
    }
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

private final class AcceptanceReader: BConnectedAccountAcceptanceReading {
    var steps: [BConnectedAccountAcceptanceStep] = []
    var beforeReturn: ((BConnectedAccountAcceptanceStep) throws -> Void)?
    func read(_ step: BConnectedAccountAcceptanceStep, record: BConnectedEnrollmentRecord, configuration: BConnectedPublicationConfiguration) async throws {
        steps.append(step)
        try beforeReturn?(step)
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
    nonisolated(unsafe) static var contentType = "application/json"
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.calls += 1
        var headers = ["Content-Type": Self.contentType]
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

// Native crypto fixture; SQLCipher probes separately exercise production allocation and persistence.
private func testPreKeyBatch(_ identity: BConnectedEnrollmentRecord.Identity) throws -> BConnectedEnrollmentRecord.PreKeyPublication.Batch {
    let pair = try IdentityKeyPair(bytes: identity.pair)
    let ec = try (1...100).map { id -> Data in
        let key = PrivateKey.generate()
        return try LibSignalClient.PreKeyRecord(id: UInt32(id), publicKey: key.publicKey, privateKey: key).serialize()
    }
    let firstPQ = (101...200).contains(Int(try LibSignalClient.KyberPreKeyRecord(bytes: identity.lastResortPreKey).id)) ? 301 : 101
    let pq = try (firstPQ..<(firstPQ + 100)).map { id -> Data in
        let key = KEMKeyPair.generate()
        return try LibSignalClient.KyberPreKeyRecord(id: UInt32(id), timestamp: 1, keyPair: key,
            signature: pair.privateKey.generateSignature(message: key.publicKey.serialize())).serialize()
    }
    return .init(ec: ec, pq: pq, request: try BConnectedEnrollmentRecord.PreKeyPublication.Batch.request(ec: ec, pq: pq, identity: identity))
}
private final class PreKeySender: BConnectedPreKeySending {
    var identities: [BConnectedPreKeyIdentity] = []
    var bodies: [Data] = []
    var fail = false
    var beforeSend: ((BConnectedPreKeyIdentity, BConnectedEnrollmentRecord) throws -> Void)?
    func send(_ identity: BConnectedPreKeyIdentity, record: BConnectedEnrollmentRecord, configuration: BConnectedPublicationConfiguration) async throws {
        try beforeSend?(identity, record)
        identities.append(identity); bodies.append(record.preKeyPublication!.batch(identity).request)
        if fail { throw CancellationError() }
    }
}
