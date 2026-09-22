//
// Copyright 2020 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

extension Upload {
    public enum CDN0 {
        public struct Form: Codable {
            let acl: String
            let key: String
            let policy: String
            let algorithm: String
            let credential: String
            let date: String
            let signature: String
            let attachmentId: UInt64?
            let attachmentIdString: String?
            // Parsed metadata is not an enabled upload route. Generic CDN0 must reject it.
            let ownedDestination: OwnedDestination?

            struct OwnedDestination: Codable {
                let url: URL
                let expiresAt: UInt64
                let maxContentLength: UInt32
            }
        }
    }
}

extension Upload.CDN0.Form {
    public enum ParsingError: Error {
        case missingField(String)
        case unsupportedAlgorithm
        case invalidGoogleAcl
        case invalidOwnedGroupForm
        case ownedGroupRouteUnavailable
    }

    public static func parse(proto: GroupsProtoAvatarUploadAttributes) throws -> Self {
        guard proto.uploadURL == nil, proto.expiresAt == 0, proto.maxContentLength == 0 else {
            throw ParsingError.ownedGroupRouteUnavailable
        }
        return try parseFields(proto: proto, ownedDestination: nil)
    }

    /// Contract parser only. No endpoint defaults, session construction, capability or upload.
    static func parseOwnedGroup(proto: GroupsProtoAvatarUploadAttributes, expectedBucket: String,
        expectedSigner: String, expectedGroupId: Data, encryptedLength: Int, now: Date
    ) throws -> Self {
        let maximum: UInt32 = 3_145_728
        guard (3...63).contains(expectedBucket.utf8.count), expectedBucket.first != "-", expectedBucket.last != "-",
              expectedBucket.utf8.allSatisfy({ (48...57).contains($0) || (97...122).contains($0) || $0 == 45 }),
              expectedGroupId.count == 32, !expectedSigner.isEmpty,
              let rawURL = proto.uploadURL, rawURL == "https://storage.googleapis.com/" + expectedBucket + "/",
              let url = URL(string: rawURL), proto.algorithm == "GOOG4-RSA-SHA256", proto.acl == nil,
              proto.maxContentLength == maximum, (1...Int(maximum)).contains(encryptedLength),
              Double(proto.expiresAt) > now.timeIntervalSince1970,
              Double(proto.expiresAt) <= now.timeIntervalSince1970 + 305,
              let key = proto.key, let date = proto.date, let credential = proto.credential,
              date.utf8.count == 16, date.range(of: #"^[0-9]{8}T[0-9]{6}Z$"#, options: .regularExpression) != nil,
              credential == expectedSigner + "/" + date.prefix(8) + "/auto/storage/goog4_request",
              let signature = proto.signature, (512...1024).contains(signature.utf8.count), signature.utf8.count.isMultiple(of: 2),
              signature.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw ParsingError.invalidOwnedGroupForm
        }
        func base64url(_ data: Data) -> String {
            data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        let prefix = "groups/" + base64url(expectedGroupId) + "/"
        guard key.hasPrefix(prefix) else { throw ParsingError.invalidOwnedGroupForm }
        let leaf = String(key.dropFirst(prefix.count))
        guard leaf.count == 22, let objectId = Data(base64Encoded: leaf.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "=="),
              objectId.count == 16, base64url(objectId) == leaf,
              let encodedPolicy = proto.policy, encodedPolicy.utf8.count <= 16_384,
              let policyBytes = Data(base64Encoded: encodedPolicy), policyBytes.base64EncodedString() == encodedPolicy,
              let policy = try? JSONSerialization.jsonObject(with: policyBytes) as? [String: Any],
              Set(policy.keys) == ["expiration", "conditions"], let expiration = policy["expiration"] as? String,
              let conditions = policy["conditions"] as? [Any] else { throw ParsingError.invalidOwnedGroupForm }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var policyDate = formatter.date(from: expiration)
        if policyDate == nil { formatter.formatOptions = [.withInternetDateTime]; policyDate = formatter.date(from: expiration) }
        guard let policyDate, floor(policyDate.timeIntervalSince1970) == Double(proto.expiresAt),
              policyDate.timeIntervalSince1970 > now.timeIntervalSince1970,
              policyDate.timeIntervalSince1970 <= now.timeIntervalSince1970 + 305 else { throw ParsingError.invalidOwnedGroupForm }
        var fields: [String: String] = [:]
        var foundSize = false
        for condition in conditions {
            if let field = condition as? [String: String], field.count == 1, let pair = field.first, fields[pair.key] == nil {
                fields[pair.key] = pair.value
            } else if let range = condition as? [Any], range.count == 3, range[0] as? String == "content-length-range",
                      let lower = range[1] as? NSNumber, let upper = range[2] as? NSNumber,
                      CFGetTypeID(lower) != CFBooleanGetTypeID(), CFGetTypeID(upper) != CFBooleanGetTypeID(),
                      lower.doubleValue == 1, upper.doubleValue == Double(maximum), !foundSize {
                foundSize = true
            } else { throw ParsingError.invalidOwnedGroupForm }
        }
        guard foundSize, fields == ["bucket": expectedBucket, "key": key, "content-type": "application/octet-stream",
            "x-goog-algorithm": "GOOG4-RSA-SHA256", "x-goog-credential": credential, "x-goog-date": date] else {
            throw ParsingError.invalidOwnedGroupForm
        }
        return try parseFields(proto: proto, ownedDestination: .init(url: url, expiresAt: proto.expiresAt, maxContentLength: maximum))
    }

    private static func parseFields(proto: GroupsProtoAvatarUploadAttributes, ownedDestination: OwnedDestination?) throws -> Self {
        // Proto3 omits an empty ACL. Only Google uses an intentionally absent ACL.
        let acl: String
        if proto.algorithm == "GOOG4-RSA-SHA256" {
            guard proto.acl == nil else { throw ParsingError.invalidGoogleAcl }
            acl = ""
        } else {
            guard let value = proto.acl else { throw ParsingError.missingField("acl") }
            acl = value
        }
        guard let key = proto.key else { throw ParsingError.missingField("key") }
        guard let policy = proto.policy else { throw ParsingError.missingField("policy") }
        guard let algorithm = proto.algorithm else { throw ParsingError.missingField("algorithm") }
        guard let credential = proto.credential else { throw ParsingError.missingField("credential") }
        guard let date = proto.date else { throw ParsingError.missingField("date") }
        guard let signature = proto.signature else { throw ParsingError.missingField("signature") }

        return .init(
            acl: acl,
            key: key,
            policy: policy,
            algorithm: algorithm,
            credential: credential,
            date: date,
            signature: signature,
            attachmentId: nil,
            attachmentIdString: nil,
            ownedDestination: ownedDestination,
        )
    }
}

extension Upload.CDN0 {
    public static func upload(data: Data, uploadForm: Upload.CDN0.Form) async throws -> String {
        guard uploadForm.ownedDestination == nil else { throw Upload.CDN0.Form.ParsingError.ownedGroupRouteUnavailable }
        if DependenciesBridge.shared.appExpiry.isExpired(now: Date()) {
            throw AppExpiredError()
        }

        let cdn0UrlSession = try await SSKEnvironment.shared.signalServiceRef.sharedUrlSessionForCdn(cdnNumber: 0)
        let dataFileUrl = OWSFileSystem.temporaryFileUrl(
            fileExtension: nil,
            isAvailableWhileDeviceLocked: true,
        )
        try data.write(to: dataFileUrl)

        // urlPath is "" for all endpoints that still use CDN0
        let request = try cdn0UrlSession.endpoint.buildRequest("", method: .post)

        // We have to build up the form manually vs. simply passing in a parameters dict
        // because AWS is sensitive to the order of the form params (at least the "key"
        // field must occur early on).
        //
        // For consistency, all fields are ordered here in a known working order.
        let textParts = try uploadForm.asOrderedDictionary

        do {
            _ = try await cdn0UrlSession.performMultiPartUpload(
                request: request,
                fileUrl: dataFileUrl,
                name: "file",
                fileName: "file",
                mimeType: MimeType.applicationOctetStream.rawValue,
                textParts: textParts,
                maxResponseSize: .max,
            )
        } catch {
            Logger.warn("\(error)")
            throw error
        }

        return uploadForm.key
    }
}

// See the AWS and Google Cloud Storage V4 POST policy multipart specifications.
extension Upload.CDN0.Form {
    var asOrderedDictionary: OrderedDictionary<String, String> {
        get throws {
            let signingFieldPrefix: String
            switch self.algorithm {
            case "AWS4-HMAC-SHA256":
                signingFieldPrefix = "x-amz"
            case "GOOG4-RSA-SHA256":
                // GCS avatars use uniform bucket-level IAM. An object ACL is neither needed nor accepted.
                guard self.acl.isEmpty else { throw ParsingError.invalidGoogleAcl }
                signingFieldPrefix = "x-goog"
            default:
                throw ParsingError.unsupportedAlgorithm
            }
            // We have to build up the form manually vs. simply passing in a parameters dict
            // because AWS is sensitive to the order of the form params (at least the "key"
            // field must occur early on).
            var result = OrderedDictionary<String, String>()

            // For consistency, all fields are ordered here in a known working order.
            result.append(key: "key", value: self.key)
            if !self.acl.isEmpty {
                result.append(key: "acl", value: self.acl)
            }
            result.append(key: "\(signingFieldPrefix)-algorithm", value: self.algorithm)
            result.append(key: "\(signingFieldPrefix)-credential", value: self.credential)
            result.append(key: "\(signingFieldPrefix)-date", value: self.date)
            result.append(key: "policy", value: self.policy)
            result.append(key: "\(signingFieldPrefix)-signature", value: self.signature)
            result.append(key: self.algorithm == "GOOG4-RSA-SHA256" ? "content-type" : "Content-Type", value: MimeType.applicationOctetStream.rawValue)
            return result
        }
    }

}
