// Copyright 2026 BConnected contributors. SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import CoreFoundation
import CryptoKit
import LibSignalClient

/// Authentication of owned historical state only. Neither signature nor rollback memory is a
/// current admission/role/device grant. No route, key discovery, receiver or readiness is enabled.
enum BConnectedGroupManifest {
    enum Rejected: Error { case invalid, untrustedKey, stale }
    enum Purpose { case currentResponse, historicalSnapshot }
    static let type = "bconnected-group-manifest-v1"
    static let issuer = "bconnected-group-authority"
    static let audience = "bconnected-owned-clients"
    static let maximumNativeBytes = 8 * 1024 * 1024
    static let maximumPayloadBytes = 4 * 1024 * 1024
    static let maximumJWSBytes = 6 * 1024 * 1024

    struct Pin: CustomStringConvertible {
        let keyId: String
        fileprivate let key: Curve25519.Signing.PublicKey
        fileprivate let currentResponsesAllowed: Bool
        /// Explicit public JWK; no embedded private key, discovery URL, certificate or extra field.
        init(jwk: Data, currentResponsesAllowed: Bool) throws {
            let value = try json(jwk, maximumBytes: 2048)
            try fields(value, ["kty", "crv", "x", "alg", "use", "kid"])
            let id = try text(value, "kid")
            guard try text(value, "kty") == "OKP", try text(value, "crv") == "Ed25519",
                  try text(value, "alg") == "Ed25519", try text(value, "use") == "sig", validKeyId(id) else { throw Rejected.invalid }
            let bytes = try decode(text(value, "x"), maximumBytes: 32)
            guard bytes.count == 32 else { throw Rejected.invalid }
            self.key = try Curve25519.Signing.PublicKey(rawRepresentation: bytes)
            self.keyId = id; self.currentResponsesAllowed = currentResponsesAllowed
        }
        var description: String { "BConnectedGroupManifest.Pin[redacted]" }
    }

    struct KnownState: Codable, Equatable {
        let revision: UInt32
        let nativeHash: Data
        let payloadHash: Data
        func validate() throws {
            guard nativeHash.count == 32, payloadHash.count == 32 else { throw Rejected.invalid }
        }
    }

    struct RosterEntry: Equatable {
        let aci: Aci
        let state: String
        let role: GroupsProtoMemberRole
        let principal: Data
    }

    /// The initializer is private to this verifier. Values are immutable and retain exact bytes.
    /// This cannot be substituted for the future authenticated outer message/current response context.
    struct VerifiedSnapshot: CustomStringConvertible {
        let groupId: Data
        let knownState: KnownState
        let nativeBytes: Data
        let roster: [RosterEntry]
        let keyId: String
        fileprivate let purpose: Purpose
        fileprivate init(groupId: Data, knownState: KnownState, nativeBytes: Data, roster: [RosterEntry], keyId: String, purpose: Purpose) {
            self.groupId = groupId; self.knownState = knownState; self.nativeBytes = nativeBytes
            self.roster = roster; self.keyId = keyId; self.purpose = purpose
        }
        var description: String { "BConnectedGroupManifest.VerifiedSnapshot[redacted]" }
    }

    struct Verifier {
        private let pins: [String: Pin]
        init(pins: [Pin]) throws {
            guard (1...8).contains(pins.count), Set(pins.map(\.keyId)).count == pins.count else { throw Rejected.invalid }
            self.pins = Dictionary(uniqueKeysWithValues: pins.map { ($0.keyId, $0) })
        }

        func verify(compactJWS: String, nativeBytes: Data, expectedGroupId: Data,
                    secretParams: GroupSecretParams, knownState: KnownState?, purpose: Purpose) throws -> VerifiedSnapshot {
            do {
                guard expectedGroupId.count == 32, !nativeBytes.isEmpty, nativeBytes.count <= maximumNativeBytes,
                      !compactJWS.isEmpty, compactJWS.utf8.count <= maximumJWSBytes else { throw Rejected.invalid }
                let parts = compactJWS.split(separator: ".", maxSplits: 3, omittingEmptySubsequences: false)
                guard parts.count == 3 else { throw Rejected.invalid }
                let header = try json(decode(String(parts[0]), maximumBytes: 1024), maximumBytes: 1024)
                let payloadBytes = try decode(String(parts[1]), maximumBytes: maximumPayloadBytes)
                let signature = try decode(String(parts[2]), maximumBytes: 64)
                try fields(header, ["alg", "kid", "typ"])
                guard try text(header, "alg") == "Ed25519", try text(header, "typ") == type, signature.count == 64 else { throw Rejected.invalid }
                let keyId = try text(header, "kid")
                guard validKeyId(keyId), let pin = pins[keyId], purpose == .historicalSnapshot || pin.currentResponsesAllowed else { throw Rejected.untrustedKey }
                // RFC 7515: verify received protected-header/payload segments, never reserialized JSON.
                guard pin.key.isValidSignature(signature, for: Data((parts[0] + "." + parts[1]).utf8)) else { throw Rejected.invalid }
                let payload = try json(payloadBytes, maximumBytes: maximumPayloadBytes)
                try fields(payload, ["schemaVersion", "iss", "aud", "groupId", "publicParamsSha256", "authorityRevision", "nativeRevision", "nativeSha256", "announcementsOnly", "terminated", "access", "directoryListed", "roster"])
                guard try integer(payload, "schemaVersion") == 1, try text(payload, "iss") == issuer, try text(payload, "aud") == audience,
                      try decode(text(payload, "groupId"), maximumBytes: 32) == expectedGroupId,
                      let entries = payload["roster"] as? [[String: Any]], (1...8000).contains(entries.count) else { throw Rejected.invalid }
                let revision = try integer(payload, "authorityRevision")
                let nativeHash = hash(nativeBytes), payloadHash = hash(payloadBytes)
                let next = KnownState(revision: revision, nativeHash: nativeHash, payloadHash: payloadHash)
                try check(next, after: knownState)
                // Bound repeated protobuf allocations before invoking the generated decoder.
                // Hashing still uses the exact received bytes; this is only a resource preflight.
                try preflightNative(nativeBytes, rosterCount: entries.count)
                let group = try GroupsProtoGroup(serializedData: nativeBytes)
                guard !group.hasUnknownFields, let publicBytes = group.publicKey,
                      let access = group.accessControl, !access.hasUnknownFields,
                      access.attributes == .administrator, access.members == .administrator,
                      access.addFromInviteLink == .unsatisfiable, access.memberLabel == .unknown,
                      group.requestingMembers.isEmpty, group.bannedMembers.isEmpty, group.inviteLinkPassword == nil,
                      group.revision == revision, group.members.count + group.pendingMembers.count == entries.count else { throw Rejected.invalid }
                let params = try GroupPublicParams(contents: publicBytes)
                guard params.serialize() == publicBytes, try params.getGroupIdentifier().serialize() == expectedGroupId,
                      try secretParams.getPublicParams().serialize() == publicBytes else { throw Rejected.invalid }
                let cipher = ClientZkGroupCipher(groupSecretParams: secretParams)
                var native: [Data: (GroupsProtoMember, String)] = [:]
                for member in group.members {
                    guard let principal = member.userID, native[principal] == nil else { throw Rejected.invalid }
                    native[principal] = (member, "ACTIVE")
                }
                for pending in group.pendingMembers {
                    guard !pending.hasUnknownFields, let member = pending.member, let principal = member.userID,
                          let inviter = pending.addedByUserID, native[principal] == nil,
                          try cipher.decrypt(UuidCiphertext(contents: inviter)) is Aci else { throw Rejected.invalid }
                    native[principal] = (member, "INVITED")
                }
                guard native.count == entries.count else { throw Rejected.invalid }
                var prior = "", principals = Set<Data>(), roster: [RosterEntry] = [], admins = 0
                for entry in entries {
                    try fields(entry, ["aci", "state", "role", "declaredPrincipal"])
                    let id = try text(entry, "aci"), state = try text(entry, "state"), roleText = try text(entry, "role")
                    guard let uuid = UUID(uuidString: id), uuid.uuidString.lowercased() == id, id > prior,
                          id != "00000000-0000-0000-0000-000000000000",
                          state == "ACTIVE" || state == "INVITED", roleText == "DEFAULT" || roleText == "ADMINISTRATOR" else { throw Rejected.invalid }
                    prior = id
                    let role: GroupsProtoMemberRole = roleText == "DEFAULT" ? .default : .administrator
                    let principal = try decode(text(entry, "declaredPrincipal"), maximumBytes: 128)
                    let ciphertext = try UuidCiphertext(contents: principal)
                    let aci = Aci(fromUUID: uuid)
                    guard ciphertext.serialize() == principal, principals.insert(principal).inserted,
                          let (member, nativeState) = native.removeValue(forKey: principal), nativeState == state,
                          !member.hasUnknownFields, member.role == role, member.presentation == nil,
                          try cipher.decrypt(ciphertext) == aci else { throw Rejected.invalid }
                    if state == "ACTIVE" {
                        guard let bytes = member.profileKey else { throw Rejected.invalid }
                        let encrypted = try ProfileKeyCiphertext(contents: bytes)
                        guard encrypted.serialize() == bytes else { throw Rejected.invalid }
                        _ = try cipher.decryptProfileKey(profileKeyCiphertext: encrypted, userId: aci)
                        if role == .administrator { admins += 1 }
                    } else {
                        guard role == .default, member.profileKey == nil else { throw Rejected.invalid }
                    }
                    roster.append(.init(aci: aci, state: state, role: role, principal: principal))
                }
                guard native.isEmpty, admins > 0 else { throw Rejected.invalid }
                // Schema-defined fixed serialization, checked only AFTER received-byte signature and
                // strict native/decrypted roster validation. No protobuf reserialization is hashed.
                let projected = projection(groupId: expectedGroupId, publicHash: hash(publicBytes), revision: revision,
                                           nativeHash: nativeHash, announcements: group.announcementsOnly, terminated: group.terminated, roster: entries)
                guard Data(projected.utf8) == payloadBytes else { throw Rejected.invalid }
                return VerifiedSnapshot(groupId: expectedGroupId, knownState: next, nativeBytes: nativeBytes, roster: roster, keyId: keyId, purpose: purpose)
            } catch let error as Rejected { throw error }
            catch { throw Rejected.invalid }
        }
    }

    static func check(_ next: KnownState, after saved: KnownState?) throws {
        try next.validate()
        guard let saved else { return }
        try saved.validate()
        guard next.revision > saved.revision || next == saved else { throw Rejected.stale }
    }
    static func hash(_ bytes: Data) -> Data { Data(SHA256.hash(data: bytes)) }
    private static func preflightNative(_ bytes: Data, rosterCount: Int) throws {
        let input = Array(bytes); var index = 0, members = 0
        func varint() throws -> UInt64 {
            var value: UInt64 = 0
            for shift in stride(from: 0, through: 63, by: 7) {
                guard index < input.count else { throw Rejected.invalid }
                let byte = input[index]; index += 1
                guard shift != 63 || byte <= 1 else { throw Rejected.invalid }
                value |= UInt64(byte & 0x7f) << shift
                if byte & 0x80 == 0 { return value }
            }
            throw Rejected.invalid
        }
        while index < input.count {
            let tag = try varint(), field = tag >> 3, wire = tag & 7
            guard (1...14).contains(field), field != 9, field != 13 else { throw Rejected.invalid }
            if field == 7 || field == 8 {
                members += 1
                guard wire == 2, members <= rosterCount else { throw Rejected.invalid }
            }
            let length: UInt64
            switch wire {
            case 0: _ = try varint(); continue
            case 1: length = 8
            case 2: length = try varint()
            case 5: length = 4
            default: throw Rejected.invalid
            }
            guard length <= UInt64(input.count - index) else { throw Rejected.invalid }
            index += Int(length)
        }
        guard members == rosterCount else { throw Rejected.invalid }
    }
    static func encode(_ bytes: Data) -> String { bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    static func decode(_ text: String, maximumBytes: Int) throws -> Data {
        guard !text.isEmpty, text.utf8.count <= (maximumBytes * 4 + 2) / 3,
              text.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else { throw Rejected.invalid }
        let base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard let bytes = Data(base64Encoded: base64 + String(repeating: "=", count: (4 - base64.utf8.count % 4) % 4)),
              bytes.count <= maximumBytes, encode(bytes) == text else { throw Rejected.invalid }
        return bytes
    }
    private static func validKeyId(_ text: String) -> Bool {
        (1...64).contains(text.utf8.count) && text.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }
    }
    private static func fields(_ value: [String: Any], _ expected: Set<String>) throws {
        guard Set(value.keys) == expected else { throw Rejected.invalid }
    }
    private static func text(_ value: [String: Any], _ key: String) throws -> String {
        guard let text = value[key] as? String else { throw Rejected.invalid }; return text
    }
    private static func integer(_ value: [String: Any], _ key: String) throws -> UInt32 {
        guard let n = value[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
              !["f", "d"].contains(String(cString: n.objCType)), let number = UInt32(n.stringValue) else { throw Rejected.invalid }
        return number
    }
    private static func projection(groupId: Data, publicHash: Data, revision: UInt32, nativeHash: Data,
                                   announcements: Bool, terminated: Bool, roster: [[String: Any]]) -> String {
        let entries = roster.map { entry in
            "{\"aci\":\"\(entry["aci"] as! String)\",\"state\":\"\(entry["state"] as! String)\",\"role\":\"\(entry["role"] as! String)\",\"declaredPrincipal\":\"\(entry["declaredPrincipal"] as! String)\"}"
        }.joined(separator: ",")
        return "{\"schemaVersion\":1,\"iss\":\"\(issuer)\",\"aud\":\"\(audience)\",\"groupId\":\"\(encode(groupId))\",\"publicParamsSha256\":\"\(encode(publicHash))\",\"authorityRevision\":\(revision),\"nativeRevision\":\(revision),\"nativeSha256\":\"\(encode(nativeHash))\",\"announcementsOnly\":\(announcements),\"terminated\":\(terminated),\"access\":{\"attributes\":\"ADMINISTRATOR\",\"members\":\"ADMINISTRATOR\",\"addFromInviteLink\":\"UNSATISFIABLE\",\"memberLabel\":\"UNKNOWN\"},\"directoryListed\":false,\"roster\":[\(entries)]}"
    }
    private static func json(_ bytes: Data, maximumBytes: Int) throws -> [String: Any] {
        var scanner = JSONScanner(bytes: bytes, maximumBytes: maximumBytes)
        try scanner.validate()
        guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw Rejected.invalid }
        return object
    }
    /// Bounded grammar check before Foundation parsing. Decoded keys catch escaped duplicates.
    private struct JSONScanner {
        let bytes: Data
        let maximumBytes: Int
        private var input: [UInt8] = []
        private var index = 0
        init(bytes: Data, maximumBytes: Int) { self.bytes = bytes; self.maximumBytes = maximumBytes }
        mutating func validate() throws {
            guard !bytes.isEmpty, bytes.count <= maximumBytes, String(data: bytes, encoding: .utf8) != nil else { throw Rejected.invalid }
            input = Array(bytes); try value(depth: 0); space()
            guard index == input.count else { throw Rejected.invalid }
        }
        mutating func space() { while index < input.count && [9, 10, 13, 32].contains(input[index]) { index += 1 } }
        mutating func consume(_ byte: UInt8) throws {
            space(); guard index < input.count, input[index] == byte else { throw Rejected.invalid }; index += 1
        }
        mutating func string() throws -> String {
            space(); let start = index; try consume(34)
            while index < input.count {
                let byte = input[index]; index += 1
                if byte == 92 { guard index < input.count else { break }; index += 1 }
                else if byte == 34 {
                    let text = try JSONDecoder().decode(String.self, from: Data(input[start..<index]))
                    guard text.utf16.count <= 2048 else { throw Rejected.invalid }; return text
                }
            }
            throw Rejected.invalid
        }
        mutating func value(depth: Int) throws {
            space(); guard depth <= 8, index < input.count else { throw Rejected.invalid }
            switch input[index] {
            case 123:
                index += 1; space(); var keys = Set<String>()
                if index < input.count && input[index] == 125 { index += 1; return }
                while true {
                    guard keys.insert(try string()).inserted else { throw Rejected.invalid }
                    try consume(58); try value(depth: depth + 1); space()
                    if index < input.count && input[index] == 125 { index += 1; return }; try consume(44)
                }
            case 91:
                index += 1; space()
                if index < input.count && input[index] == 93 { index += 1; return }
                while true {
                    try value(depth: depth + 1); space()
                    if index < input.count && input[index] == 93 { index += 1; return }; try consume(44)
                }
            case 34: _ = try string()
            default:
                let start = index
                while index < input.count && ![9, 10, 13, 32, 44, 93, 125].contains(input[index]) { index += 1 }
                guard index - start <= 20 else { throw Rejected.invalid }
                let token = String(decoding: input[start..<index], as: UTF8.self)
                guard ["true", "false", "null"].contains(token) || token.range(of: #"^(0|[1-9][0-9]*)$"#, options: .regularExpression) != nil else { throw Rejected.invalid }
            }
        }
    }
}

/// Store only a rollback floor, never admission or authorization. Future group-state persistence
/// must join this same caller-owned SQLCipher transaction after all receiver/context checks.
enum BConnectedGroupManifestStore {
    private static let values = KeyValueStore(collection: "BConnectedGroupManifest.v1")
    static func load(groupId: Data, tx: DBReadTransaction) throws -> BConnectedGroupManifest.KnownState? {
        guard groupId.count == 32 else { throw BConnectedGroupManifest.Rejected.invalid }
        guard let bytes = values.getData(BConnectedGroupManifest.encode(groupId), transaction: tx) else { return nil }
        do {
            let state = try JSONDecoder().decode(BConnectedGroupManifest.KnownState.self, from: bytes)
            try state.validate(); return state
        } catch { throw BConnectedGroupManifest.Rejected.invalid }
    }
    static func remember(_ snapshot: BConnectedGroupManifest.VerifiedSnapshot, tx: DBWriteTransaction) throws {
        guard snapshot.purpose == .currentResponse else { throw BConnectedGroupManifest.Rejected.invalid }
        let prior = try load(groupId: snapshot.groupId, tx: tx)
        try BConnectedGroupManifest.check(snapshot.knownState, after: prior)
        if prior == snapshot.knownState { return }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        values.setData(try encoder.encode(snapshot.knownState), key: BConnectedGroupManifest.encode(snapshot.groupId), transaction: tx)
    }
}
