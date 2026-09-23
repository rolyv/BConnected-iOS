// Copyright 2026 BConnected contributors. SPDX-License-Identifier: AGPL-3.0-only
// Actual platform Ed25519, libsignal decryption, generated group protobufs and SQLCipher/WAL.
// All keys and groups here are synthetic; no app lifecycle, provider or network operation.
import Darwin
import Foundation
import CryptoKit
import GRDB
import LibSignalClient
@testable import SignalServiceKit

typealias Manifest = BConnectedGroupManifest
func check(_ condition: Bool) { precondition(condition) }
SetCurrentAppContext(TestAppContext(), isRunningTests: true)
precondition(CommandLine.arguments.count == 4)
let mode = CommandLine.arguments[1], path = CommandLine.arguments[2]
let fixtureURL = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("manifest-fixture.json")
let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as! [String: Any]
func binary(_ field: String) throws -> Data { try Manifest.decode(fixture[field] as! String, maximumBytes: Manifest.maximumNativeBytes) }
let jwk = try JSONSerialization.data(withJSONObject: fixture["publicJwk"]!)
let pin = try Manifest.Pin(jwk: jwk, currentResponsesAllowed: true)
let verifier = try Manifest.Verifier(pins: [pin])
let secret = try GroupSecretParams(contents: binary("syntheticGroupSecretParams"))
let native = try binary("nativeGroup"), groupId = try binary("groupId")
let compact = fixture["compactJws"] as! String, payload = fixture["canonicalPayload"] as! String
let first = try verifier.verify(compactJWS: compact, nativeBytes: native, expectedGroupId: groupId, secretParams: secret, knownState: nil, purpose: .currentResponse)
try check(first.knownState.nativeHash == binary("nativeSha256"))
try check(first.knownState.payloadHash == binary("payloadSha256"))
precondition(first.roster.map { $0.aci.serviceIdString.lowercased() } == fixture["expectedDecryptedAcis"] as! [String])

// A fresh in-memory test signer lets negative tests carry valid signatures. No private key is saved.
let localKey = Curve25519.Signing.PrivateKey()
let localJWK: [String: Any] = ["kty": "OKP", "crv": "Ed25519", "alg": "Ed25519", "use": "sig", "kid": "ios-synthetic", "x": Manifest.encode(localKey.publicKey.rawRepresentation)]
let localPin = try Manifest.Pin(jwk: JSONSerialization.data(withJSONObject: localJWK), currentResponsesAllowed: true)
let localVerifier = try Manifest.Verifier(pins: [localPin])
let header = "{\"alg\":\"Ed25519\",\"kid\":\"ios-synthetic\",\"typ\":\"bconnected-group-manifest-v1\"}"
func sign(_ body: Data, header: String = header) throws -> String {
    let input = Manifest.encode(Data(header.utf8)) + "." + Manifest.encode(body)
    return input + "." + Manifest.encode(try localKey.signature(for: Data(input.utf8)))
}
func verifyLocal(_ body: String, nativeBytes: Data = native, header: String = header, known: Manifest.KnownState? = nil) throws -> Manifest.VerifiedSnapshot {
    try localVerifier.verify(compactJWS: sign(Data(body.utf8), header: header), nativeBytes: nativeBytes,
        expectedGroupId: groupId, secretParams: secret, knownState: known, purpose: .currentResponse)
}
func bodyForNative(_ bytes: Data, revision: UInt32? = nil) -> String {
    var body = payload.replacingOccurrences(of: fixture["nativeSha256"] as! String, with: Manifest.encode(Manifest.hash(bytes)))
    if let revision {
        body = body.replacingOccurrences(of: "\"authorityRevision\":0", with: "\"authorityRevision\":\(revision)")
            .replacingOccurrences(of: "\"nativeRevision\":0", with: "\"nativeRevision\":\(revision)")
    }
    return body
}
let proto = try GroupsProtoGroup(serializedData: native)
var advancedBuilder = proto.asBuilder(); advancedBuilder.setRevision(1)
let advancedBytes = try advancedBuilder.buildSerializedData()
let advanced = try verifyLocal(bodyForNative(advancedBytes, revision: 1), nativeBytes: advancedBytes)

let keyFetcher = GRDBKeyFetcher(keychainStorage: MockKeychainStorage())
try keyFetcher.store(data: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3])))
var configuration = GRDB.Configuration(); configuration.acceptsDoubleQuotedStringLiterals = true; configuration.defaultTransactionKind = .immediate
configuration.prepareDatabase { try GRDBDatabaseStorageAdapter.prepareDatabase(db: $0, keyFetcher: keyFetcher) }
let database = try DatabasePool(path: path, configuration: configuration)
if mode == "initialize" { try GRDBSchemaMigrator.runIncrementalMigrations(databaseWriter: database) }
try database.read { db in
    try check(String.fetchOne(db, sql: "PRAGMA journal_mode") == "wal")
    try check(String.fetchOne(db, sql: "PRAGMA integrity_check") == "ok")
    try check(String.fetchAll(db, sql: "PRAGMA cipher_integrity_check").isEmpty)
}
func write(_ body: (DBWriteTransaction) throws -> Void) throws {
    try database.write { db in
        let tx = DBWriteTransaction(database: db); defer { tx.finalizeTransaction() }
        try body(tx); precondition(tx.completionBlocks.isEmpty)
    }
}
func crash() -> Never {
    try! Data(mode.utf8).write(to: URL(fileURLWithPath: path + ".kill-point"), options: .atomic)
    kill(getpid(), SIGKILL); fatalError("SIGKILL returned")
}
var checks = 0
func reject(line: UInt = #line, _ body: () throws -> Void) {
    do { try body(); preconditionFailure("invalid manifest accepted at probe line \(line), case \(checks + 1)") } catch { checks += 1 }
}

switch mode {
case "initialize":
    precondition(first.nativeBytes == native && first.roster.count == 3)
    let rotated = try verifyLocal(payload, known: first.knownState)
    precondition(rotated.knownState == first.knownState)
    var maximumBuilder = proto.asBuilder(); maximumBuilder.setRevision(UInt32.max)
    let maximumBytes = try maximumBuilder.buildSerializedData()
    let maximum = try verifyLocal(bodyForNative(maximumBytes, revision: UInt32.max), nativeBytes: maximumBytes)
    precondition(first.knownState.revision == 0 && maximum.knownState.revision == UInt32.max)
    _ = try verifyLocal(payload, header: "{ \"typ\":\"bconnected-group-manifest-v1\",\"kid\":\"ios-synthetic\",\"alg\":\"Ed25519\" }")
    let retired = try Manifest.Verifier(pins: [.init(jwk: jwk, currentResponsesAllowed: false)])
    reject { _ = try retired.verify(compactJWS: compact, nativeBytes: native, expectedGroupId: groupId, secretParams: secret, knownState: nil, purpose: .currentResponse) }
    _ = try retired.verify(compactJWS: compact, nativeBytes: native, expectedGroupId: groupId, secretParams: secret, knownState: nil, purpose: .historicalSnapshot)
    reject { _ = try Manifest.Verifier(pins: []) }
    reject { _ = try Manifest.Verifier(pins: [pin, pin]) }
    for (key, value) in [("d", "not-a-public-key"), ("jku", "https://example.invalid"), ("alg", "EdDSA"), ("crv", "X25519")] {
        var valueJWK = localJWK; valueJWK[key] = value
        reject { _ = try Manifest.Pin(jwk: JSONSerialization.data(withJSONObject: valueJWK), currentResponsesAllowed: true) }
    }
    var wrongJWK = fixture["publicJwk"] as! [String: Any]; wrongJWK["x"] = fixture["wrongSigningPublicKey"]
    let wrong = try Manifest.Verifier(pins: [.init(jwk: JSONSerialization.data(withJSONObject: wrongJWK), currentResponsesAllowed: true)])
    reject { _ = try wrong.verify(compactJWS: compact, nativeBytes: native, expectedGroupId: groupId, secretParams: secret, knownState: nil, purpose: .currentResponse) }
    for saved in [nil, first.knownState] {
        reject { _ = try verifier.verify(compactJWS: fixture["sameRevisionDifferentClearRosterJws"] as! String,
            nativeBytes: native, expectedGroupId: groupId, secretParams: secret, knownState: saved, purpose: .currentResponse) }
    }
    reject { _ = try verifier.verify(compactJWS: compact, nativeBytes: native, expectedGroupId: Data(repeating: 0, count: 32), secretParams: secret, knownState: nil, purpose: .currentResponse) }
    reject { _ = try verifier.verify(compactJWS: compact, nativeBytes: native, expectedGroupId: groupId, secretParams: GroupSecretParams.generate(), knownState: nil, purpose: .currentResponse) }
    for bad in [header.replacingOccurrences(of: "Ed25519", with: "EdDSA"), header.replacingOccurrences(of: "Ed25519", with: "none"),
                header.replacingOccurrences(of: "ios-synthetic", with: "unknown"), header.replacingOccurrences(of: Manifest.type, with: "wrong-type"),
                header.dropLast() + ",\"crit\":[]}", header.dropLast() + ",\"b64\":true}", header.dropLast() + ",\"jwk\":{}}",
                header.dropLast() + ",\"alg\":\"Ed25519\"}", header.dropLast() + ",\"\\u0061lg\":\"Ed25519\"}"] {
        reject { _ = try verifyLocal(payload, header: String(bad)) }
    }
    for bad in [" " + payload, payload + "{}", payload.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":true"),
                payload.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":1.0"),
                payload.replacingOccurrences(of: "\"authorityRevision\":0", with: "\"authorityRevision\":4294967296"),
                payload.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":1,\"schemaVersion\":1"),
                payload.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":1,\"\\u0073chemaVersion\":1"),
                payload.replacingOccurrences(of: "bconnected-owned-clients", with: "wrong-audience"),
                payload.replacingOccurrences(of: "\"directoryListed\":false", with: "\"directoryListed\":true"),
                payload.replacingOccurrences(of: "\"announcementsOnly\":true", with: "\"announcementsOnly\":false"),
                payload.replacingOccurrences(of: "\"state\":\"ACTIVE\"", with: "\"state\":\"INVITED\"")] {
        reject { _ = try verifyLocal(bad) }
    }
    reject { _ = try localVerifier.verify(compactJWS: sign(Data([0xff])), nativeBytes: native, expectedGroupId: groupId, secretParams: secret, knownState: nil, purpose: .currentResponse) }
    reject { _ = try verifyLocal(String(repeating: "[", count: 10) + "0" + String(repeating: "]", count: 10)) }
    for bad in ["", compact + ".", "=" + compact, compact + "=", " " + compact, String(repeating: ".", count: Manifest.maximumJWSBytes), String(repeating: "A", count: Manifest.maximumJWSBytes + 1)] {
        reject { _ = try verifier.verify(compactJWS: bad, nativeBytes: native, expectedGroupId: groupId, secretParams: secret, knownState: nil, purpose: .currentResponse) }
    }
    reject { _ = try verifier.verify(compactJWS: compact, nativeBytes: Data(repeating: 0, count: Manifest.maximumNativeBytes + 1), expectedGroupId: groupId, secretParams: secret, knownState: nil, purpose: .currentResponse) }
    reject { _ = try verifyLocal(payload, known: advanced.knownState) }
    for kind in 0..<5 {
        var builder = proto.asBuilder()
        var member = proto.members[0].asBuilder()
        if kind == 0 { builder.addMembers(proto.members[0]) }
        if kind == 1 { member.setRole(proto.members[0].role == .administrator ? .default : .administrator); builder.setMembers([member.buildInfallibly()] + proto.members.dropFirst()) }
        if kind == 2 { member.setProfileKey(Data([1])); builder.setMembers([member.buildInfallibly()] + proto.members.dropFirst()) }
        if kind == 3 { builder.setInviteLinkPassword(Data([1])) }
        if kind == 4 { var access = proto.accessControl!.asBuilder(); access.setMembers(.member); builder.setAccessControl(access.buildInfallibly()) }
        let changed = try builder.buildSerializedData()
        reject { _ = try verifyLocal(bodyForNative(changed), nativeBytes: changed) }
    }
    // Unknown top-level/nested fields and excessive repeated-message allocations fail closed.
    let unknown = Data([0xa0, 0x06, 0x01])
    var nestedBuilder = proto.asBuilder()
    nestedBuilder.setMembers([try GroupsProtoMember(serializedData: proto.members[0].serializedData() + unknown)] + proto.members.dropFirst())
    var accessBuilder = proto.asBuilder(); accessBuilder.setAccessControl(try GroupsProtoAccessControl(serializedData: proto.accessControl!.serializedData() + unknown))
    for changed in [native + unknown, try nestedBuilder.buildSerializedData(), native + Data(repeating: 0, count: 1),
                    try accessBuilder.buildSerializedData(),
                    native + Data(Array(repeating: [UInt8(0x3a), UInt8(0)], count: 8001).joined())] {
        reject { _ = try verifyLocal(bodyForNative(changed), nativeBytes: changed) }
    }
    // Valid invited ACI, then the same structure with a PNI principal and malformed inviter.
    let invitedIndex = proto.members.firstIndex { $0.role == .default }!
    let invited = proto.members[invitedIndex]
    let admin = proto.members.first { $0.role == .administrator }!
    var invitedMember = invited.asBuilder(); invitedMember.setProfileKey(Data())
    var pending = GroupsProtoPendingMember.builder(); pending.setMember(invitedMember.buildInfallibly()); pending.setAddedByUserID(admin.userID!)
    var invitedGroup = proto.asBuilder(); invitedGroup.setMembers(proto.members.enumerated().filter { $0.offset != invitedIndex }.map(\.element)); invitedGroup.setPendingMembers([pending.buildInfallibly()])
    let invitedBytes = try invitedGroup.buildSerializedData()
    let invitedACI = first.roster.first { $0.principal == invited.userID! }!.aci.serviceIdString.lowercased()
    let invitedBody = bodyForNative(invitedBytes).replacingOccurrences(of: "\"aci\":\"\(invitedACI)\",\"state\":\"ACTIVE\"", with: "\"aci\":\"\(invitedACI)\",\"state\":\"INVITED\"")
    let validInvite = try verifyLocal(invitedBody, nativeBytes: invitedBytes)
    precondition(validInvite.roster.filter { $0.state == "INVITED" }.count == 1)
    pending.setAddedByUserID(Data([1])); invitedGroup.setPendingMembers([pending.buildInfallibly()])
    let badInvite = try invitedGroup.buildSerializedData()
    reject { _ = try verifyLocal(invitedBody.replacingOccurrences(of: Manifest.encode(Manifest.hash(invitedBytes)), with: Manifest.encode(Manifest.hash(badInvite))), nativeBytes: badInvite) }
    pending.setAddedByUserID(admin.userID!); invitedMember.setUserID(Data([1])); pending.setMember(invitedMember.buildInfallibly()); invitedGroup.setPendingMembers([pending.buildInfallibly()])
    let badPrincipal = try invitedGroup.buildSerializedData()
    let badPrincipalBody = invitedBody.replacingOccurrences(of: Manifest.encode(Manifest.hash(invitedBytes)), with: Manifest.encode(Manifest.hash(badPrincipal))).replacingOccurrences(of: Manifest.encode(invited.userID!), with: Manifest.encode(Data([1])))
    reject { _ = try verifyLocal(badPrincipalBody, nativeBytes: badPrincipal) }
    let pniPrincipal = try ClientZkGroupCipher(groupSecretParams: secret).encrypt(Pni(fromUUID: UUID())).serialize()
    var pniMember = invited.asBuilder(); pniMember.setUserID(pniPrincipal)
    var pniGroup = proto.asBuilder(); var pniMembers = proto.members; pniMembers[invitedIndex] = pniMember.buildInfallibly(); pniGroup.setMembers(pniMembers)
    let pniBytes = try pniGroup.buildSerializedData()
    reject { _ = try verifyLocal(bodyForNative(pniBytes).replacingOccurrences(of: Manifest.encode(invited.userID!), with: Manifest.encode(pniPrincipal)), nativeBytes: pniBytes) }
    // A valid signed policy change at the same revision is rejected by the persisted payload/hash floor.
    var changedBuilder = proto.asBuilder(); changedBuilder.setAnnouncementsOnly(false)
    let changed = try changedBuilder.buildSerializedData()
    let changedBody = bodyForNative(changed).replacingOccurrences(of: "\"announcementsOnly\":true", with: "\"announcementsOnly\":false")
    _ = try verifyLocal(changedBody, nativeBytes: changed)
    reject { _ = try verifyLocal(changedBody, nativeBytes: changed, known: first.knownState) }
    print("PASS Java JWS/raw native/decrypted roster/hash interoperability, pinned rotation and \(checks) strict negative cases")
case "remember-crash", "remember-commit-crash", "advance-crash", "advance-commit-crash":
    try write { tx in
        try BConnectedGroupManifestStore.remember(mode.hasPrefix("advance") ? advanced : first, tx: tx)
        if !mode.contains("commit") { crash() }
    }
    crash()
case "verify-absent":
    try database.read { db in
        let state = try BConnectedGroupManifestStore.load(groupId: groupId, tx: DBReadTransaction(database: db))
        precondition(state == nil)
    }
    print("PASS uncommitted manifest rollback floor absent after fresh process")
case "verify-saved", "verify-advanced":
    let expected = mode == "verify-saved" ? first : advanced
    try write { tx in
        try check(BConnectedGroupManifestStore.load(groupId: groupId, tx: tx) == expected.knownState)
        let before = try Int.fetchOne(tx.database, sql: "SELECT total_changes()")!
        try BConnectedGroupManifestStore.remember(expected, tx: tx)
        try check(Int.fetchOne(tx.database, sql: "SELECT total_changes()") == before)
        if mode == "verify-advanced" {
            do { try BConnectedGroupManifestStore.remember(first, tx: tx); preconditionFailure("rollback accepted") }
            catch Manifest.Rejected.stale {}
        }
        let historical = try verifier.verify(compactJWS: compact, nativeBytes: native, expectedGroupId: groupId, secretParams: secret, knownState: nil, purpose: .historicalSnapshot)
        do { try BConnectedGroupManifestStore.remember(historical, tx: tx); preconditionFailure("history changed current rollback floor") }
        catch Manifest.Rejected.invalid {}
    }
    print("PASS \(mode): exact persisted revision/native/payload floor, zero-write repeat and rollback rejection in fresh process")
default: preconditionFailure("unknown probe mode")
}
