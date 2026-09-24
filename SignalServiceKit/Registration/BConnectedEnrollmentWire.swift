// Copyright 2026 BConnected contributors. SPDX-License-Identifier: AGPL-3.0-only

public import Foundation
import CoreFoundation
import LibSignalClient

/// Sanitized failures only; associated values must never contain wire bodies or credentials.
public enum BConnectedEnrollmentError: Error, Equatable {
    case invalidInput, invalidResponse, persistenceUnavailable, immutableConflict, unavailable
    /// Exact no-mutation denial from the owned phone-bootstrap route only.
    case phoneEnrollmentRejected
    case missingAttempt, approvalBindingRequired, operationRequired, explicitSendRequired, busy
    case explicitPublicationRetryRequired, uncertainPreKeyPublication
    case rejected(Code, retryAfterSeconds: Int?)

    public enum Code: String, Codable {
        case invalidRequest = "INVALID_REQUEST", invalidCredentials = "INVALID_CREDENTIALS"
        case enrollmentUnavailable = "ENROLLMENT_UNAVAILABLE", enrollmentConflict = "ENROLLMENT_CONFLICT"
        case enrollmentExpired = "ENROLLMENT_EXPIRED", codeNotAccepted = "CODE_NOT_ACCEPTED", codeExpired = "CODE_EXPIRED"
        case rateLimited = "RATE_LIMITED", temporarilyUnavailable = "TEMPORARILY_UNAVAILABLE"
    }
}

public enum BConnectedEnrollmentOperation: String {
    case begin, sendCode = "send-code", checkCode = "check-code", complete, status
}

/// A wire observation, never a local account-registration or membership capability.
public struct BConnectedEnrollmentObservation: Codable, Equatable {
    public enum State: String, Codable { case verification, pendingConfirmation = "pending_confirmation", active, suspended }
    public struct Account: Codable, Equatable {
        public let aci: String
        public let pni: String
        public let number: String
        public let deviceId: Int
    }
    public let operationId: String
    public let state: State
    public let registrationAuthorized: Bool
    public let phoneVerified: Bool?
    public let nextSmsSeconds: Int?
    public let nextCheckSeconds: Int?
    public let expiresInSeconds: Int?
    public let account: Account?
}

/// Shared JSON v1 validation. No upstream verification/session/identity fields are accepted.
enum BConnectedEnrollmentWire {
    static let maximumBytes = 65_536
    static let capabilities: Set<String> = ["storage", "transfer", "attachmentBackfill", "spqr", "profiles_v2", "usernameChangeSyncMessage", "optionalPhoneNumber"]

    static func encode(_ value: [String: Any]) throws -> Data {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
        guard data.count <= maximumBytes else { throw BConnectedEnrollmentError.invalidInput }
        return data
    }

    static func object(_ data: Data) throws -> [String: Any] {
        do {
            // JSONDecoder alone silently discards duplicate keys. Check original bytes first.
            var scanner = UniqueJSON(data: data)
            try scanner.validate()
            guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw BConnectedEnrollmentError.invalidInput
            }
            return value
        } catch { throw BConnectedEnrollmentError.invalidInput }
    }

    static func fields(_ value: Any?, required: Set<String>, optional: Set<String> = []) throws -> [String: Any] {
        guard let object = value as? [String: Any], required.isSubset(of: Set(object.keys)),
              Set(object.keys).isSubset(of: required.union(optional)) else { throw BConnectedEnrollmentError.invalidInput }
        return object
    }

    static func text(_ value: Any?) throws -> String {
        guard let value = value as? String else { throw BConnectedEnrollmentError.invalidInput }
        return value
    }

    static func metadata(_ value: Any?, limit: Int) throws -> String {
        let string = try text(value)
        guard !string.isEmpty, string.utf8.count <= limit,
              !string.unicodeScalars.contains(where: { $0.value < 32 || (127...159).contains($0.value) }) else {
            throw BConnectedEnrollmentError.invalidInput
        }
        return string
    }

    static func integer(_ value: Any?) throws -> Int {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              !["f", "d"].contains(String(cString: value.objCType)), let number = Int(value.stringValue) else {
            throw BConnectedEnrollmentError.invalidInput
        }
        return number
    }

    static func boolean(_ value: Any?) throws -> Bool {
        guard let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { throw BConnectedEnrollmentError.invalidInput }
        return value.boolValue
    }

    static func uuid(_ value: Any?) throws -> String {
        let value = try text(value)
        guard let id = UUID(uuidString: value), id.uuidString.lowercased() == value,
              value != "00000000-0000-0000-0000-000000000000" else { throw BConnectedEnrollmentError.invalidInput }
        return value
    }

    static func phone(_ value: String) throws {
        guard value.range(of: #"^\+[1-9][0-9]{1,14}$"#, options: .regularExpression) != nil else { throw BConnectedEnrollmentError.invalidInput }
    }

    static func base64(_ value: Any?) throws -> Data {
        let value = try text(value)
        guard let bytes = Data(base64Encoded: value), bytes.base64EncodedString() == value else { throw BConnectedEnrollmentError.invalidInput }
        return bytes
    }

    static func nonce(_ value: Any?) throws -> String {
        let value = try text(value)
        let bytes = try base64(value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "=")
        guard bytes.count == 32, base64url(bytes) == value else { throw BConnectedEnrollmentError.invalidInput }
        return value
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    @discardableResult
    static func request(_ data: Data, operation: BConnectedEnrollmentOperation) throws -> [String: Any] {
        let root = try fields(object(data), required: ["memberId", "registrationAttemptId", "bindingChallenge", "registrationRequest", "originalSignalAgent", "originalUserAgent"], optional: operation == .checkCode ? ["code"] : [])
        _ = try uuid(root["memberId"])
        _ = try nonce(root["registrationAttemptId"])
        _ = try nonce(root["bindingChallenge"])
        _ = try metadata(root["originalSignalAgent"], limit: 256)
        _ = try metadata(root["originalUserAgent"], limit: 512)
        if operation == .checkCode {
            let code = try text(root["code"])
            guard code.range(of: #"^[0-9]{4,10}$"#, options: .regularExpression) != nil else { throw BConnectedEnrollmentError.invalidInput }
        }
        _ = try registration(root["registrationRequest"])
        return root
    }

    @discardableResult
    static func registration(_ value: Any?) throws -> String {
        let request = try fields(value, required: ["accountAttributes", "skipDeviceTransfer", "aciIdentityKey", "pniIdentityKey", "aciSignedPreKey", "pniSignedPreKey", "aciPqLastResortPreKey", "pniPqLastResortPreKey"], optional: ["apnToken", "gcmToken"])
        _ = try boolean(request["skipDeviceTransfer"])
        let attrs = try fields(request["accountAttributes"], required: ["fetchesMessages", "registrationId", "pniRegistrationId", "unidentifiedAccessKey", "unrestrictedUnidentifiedAccess", "discoverableByPhoneNumber", "capabilities"], optional: ["name", "registrationLock", "recoveryPassword"])
        let fetches = try boolean(attrs["fetchesMessages"])
        let unrestricted = try boolean(attrs["unrestrictedUnidentifiedAccess"])
        _ = try boolean(attrs["discoverableByPhoneNumber"])
        let accessKey = try base64(attrs["unidentifiedAccessKey"])
        guard (accessKey.isEmpty || accessKey.count == 16), unrestricted || accessKey.count == 16 else { throw BConnectedEnrollmentError.invalidInput }
        let caps = try fields(attrs["capabilities"], required: [], optional: capabilities)
        for value in caps.values { _ = try boolean(value) }
        guard try boolean(caps["spqr"]) else { throw BConnectedEnrollmentError.invalidInput }
        for (name, length) in [("name", 225), ("recoveryPassword", 32)] {
            if let value = attrs[name], !(value is NSNull) {
                let bytes = try base64(value)
                guard name == "name" ? bytes.count <= length : bytes.count == length else { throw BConnectedEnrollmentError.invalidInput }
            }
        }
        if let value = attrs["registrationLock"], !(value is NSNull) {
            let lock = try text(value)
            guard lock.isEmpty || lock.count == 64 else { throw BConnectedEnrollmentError.invalidInput }
        }
        var channels = fetches ? 1 : 0
        for kind in ["apn", "gcm"] {
            if let value = request[kind + "Token"] {
                let token = try fields(value, required: [kind + "RegistrationId"])
                _ = try metadata(token[kind + "RegistrationId"], limit: 4096)
                channels += 1
            }
        }
        guard channels == 1 else { throw BConnectedEnrollmentError.invalidInput }
        func material(_ prefix: String, registrationId: String) throws -> BConnectedRegistrationKeyCommitment.IdentityMaterial {
            let identity = try IdentityKey(bytes: base64(request[prefix + "IdentityKey"]))
            let ec = try fields(request[prefix + "SignedPreKey"], required: ["keyId", "publicKey", "signature"])
            let kem = try fields(request[prefix + "PqLastResortPreKey"], required: ["keyId", "publicKey", "signature"])
            return .init(identityKey: identity, registrationId: try integer(attrs[registrationId]),
                         signedPreKey: .init(keyId: Int64(try integer(ec["keyId"])), publicKey: try PublicKey(base64(ec["publicKey"])), signature: try base64(ec["signature"])),
                         lastResortPreKey: .init(keyId: Int64(try integer(kem["keyId"])), publicKey: try KEMPublicKey(base64(kem["publicKey"])), signature: try base64(kem["signature"])))
        }
        do { return try BConnectedRegistrationKeyCommitment.compute(aci: material("aci", registrationId: "registrationId"), pni: material("pni", registrationId: "pniRegistrationId")) }
        catch { throw BConnectedEnrollmentError.invalidInput }
    }

    static func response(_ data: Data, status: Int, operation: BConnectedEnrollmentOperation, expectedOperation: String?, expectedPhone: String) throws -> BConnectedEnrollmentObservation {
        do {
            let root = try object(data)
            if status != 200 && status != 202 {
                let body = try fields(root, required: ["code"], optional: ["retryAfterSeconds"])
                guard let code = BConnectedEnrollmentError.Code(rawValue: try text(body["code"])) else { throw BConnectedEnrollmentError.invalidResponse }
                let statuses: [BConnectedEnrollmentError.Code: Int] = [.invalidRequest: 400, .invalidCredentials: 401, .enrollmentUnavailable: 404, .enrollmentConflict: 409, .enrollmentExpired: 410, .codeNotAccepted: 422, .rateLimited: 429, .temporarilyUnavailable: 503]
                guard statuses[code] == status else { throw BConnectedEnrollmentError.invalidResponse }
                var retry: Int?
                if let value = body["retryAfterSeconds"] { retry = try integer(value); guard retry! >= 0 else { throw BConnectedEnrollmentError.invalidResponse } }
                throw BConnectedEnrollmentError.rejected(code, retryAfterSeconds: retry)
            }
            let id = try uuid(root["operationId"])
            guard expectedOperation == nil || expectedOperation == id else { throw BConnectedEnrollmentError.invalidResponse }
            guard let state = BConnectedEnrollmentObservation.State(rawValue: try text(root["state"])) else { throw BConnectedEnrollmentError.invalidResponse }
            let authorized = try boolean(root["registrationAuthorized"])
            if state == .verification {
                _ = try fields(root, required: ["operationId", "state", "registrationAuthorized", "phoneVerified", "nextSmsSeconds", "nextCheckSeconds", "expiresInSeconds"])
                _ = try boolean(root["phoneVerified"])
                guard status == 200, !authorized, operation != .complete else { throw BConnectedEnrollmentError.invalidResponse }
                for key in ["nextSmsSeconds", "nextCheckSeconds", "expiresInSeconds"] {
                    if root[key] is NSNull { guard key != "expiresInSeconds" else { throw BConnectedEnrollmentError.invalidResponse }; continue }
                    guard try integer(root[key]) >= 0 else { throw BConnectedEnrollmentError.invalidResponse }
                }
            } else {
                _ = try fields(root, required: ["operationId", "state", "registrationAuthorized"], optional: state == .active ? ["account"] : [])
                guard operation == .complete || operation == .status, authorized == (state == .active),
                      status == (operation == .complete && state == .pendingConfirmation ? 202 : 200) else { throw BConnectedEnrollmentError.invalidResponse }
                if state == .active {
                    let account = try fields(root["account"], required: ["aci", "pni", "number", "deviceId"])
                    _ = try uuid(account["aci"]); _ = try uuid(account["pni"])
                    guard try integer(account["deviceId"]) == 1, try text(account["number"]) == expectedPhone else { throw BConnectedEnrollmentError.invalidResponse }
                }
            }
            return try JSONDecoder().decode(BConnectedEnrollmentObservation.self, from: data)
        } catch let error as BConnectedEnrollmentError {
            if case .rejected = error { throw error }
            throw BConnectedEnrollmentError.invalidResponse
        } catch { throw BConnectedEnrollmentError.invalidResponse }
    }
}

/// Bounded structural scan retaining duplicate keys (including escaped aliases) before Foundation decoding.
private struct UniqueJSON {
    let data: Data
    private var bytes: [UInt8] = []
    private var index = 0
    init(data: Data) { self.data = data }
    mutating func validate() throws {
        guard !data.isEmpty, data.count <= BConnectedEnrollmentWire.maximumBytes, String(data: data, encoding: .utf8) != nil else { throw BConnectedEnrollmentError.invalidInput }
        bytes = Array(data); try value(depth: 0); whitespace()
        guard index == bytes.count else { throw BConnectedEnrollmentError.invalidInput }
    }
    mutating private func whitespace() { while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 } }
    mutating private func consume(_ byte: UInt8) throws {
        whitespace(); guard index < bytes.count, bytes[index] == byte else { throw BConnectedEnrollmentError.invalidInput }; index += 1
    }
    mutating private func string() throws -> String {
        whitespace(); let start = index; try consume(34)
        while index < bytes.count {
            let byte = bytes[index]; index += 1
            if byte == 92 { guard index < bytes.count else { break }; index += 1 }
            else if byte == 34 { return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index])) }
        }
        throw BConnectedEnrollmentError.invalidInput
    }
    mutating private func value(depth: Int) throws {
        whitespace(); guard depth <= 12, index < bytes.count else { throw BConnectedEnrollmentError.invalidInput }
        switch bytes[index] {
        case 123:
            index += 1; whitespace(); var keys = Set<String>()
            if index < bytes.count && bytes[index] == 125 { index += 1; return }
            while true {
                guard keys.insert(try string()).inserted else { throw BConnectedEnrollmentError.invalidInput }
                try consume(58); try value(depth: depth + 1); whitespace()
                if index < bytes.count && bytes[index] == 125 { index += 1; return }; try consume(44)
            }
        case 91:
            index += 1; whitespace()
            if index < bytes.count && bytes[index] == 93 { index += 1; return }
            while true {
                try value(depth: depth + 1); whitespace()
                if index < bytes.count && bytes[index] == 93 { index += 1; return }; try consume(44)
            }
        case 34: _ = try string()
        default:
            let start = index
            while index < bytes.count && ![9, 10, 13, 32, 44, 93, 125].contains(bytes[index]) { index += 1 }
            let token = String(decoding: bytes[start..<index], as: UTF8.self)
            guard ["true", "false", "null"].contains(token) || token.range(of: #"^-?(0|[1-9][0-9]*)$"#, options: .regularExpression) != nil else { throw BConnectedEnrollmentError.invalidInput }
        }
    }
}
