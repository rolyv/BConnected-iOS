// Copyright 2026 BConnected contributors. SPDX-License-Identifier: AGPL-3.0-only
// Actual protobuf, form parser, multipart fields and generic upload boundary. No network/app setup.
import Foundation
@testable import SignalServiceKit

let now = Date(timeIntervalSince1970: 1_700_000_000)
let bucket = "bconnected-group-avatars-test"
let signer = "avatar-test@fixture.iam.gserviceaccount.com"
let group = Data(repeating: 0, count: 32)
let key = "groups/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/AAAAAAAAAAAAAAAAAAAAAA"
let credential = signer + "/20231114/auto/storage/goog4_request"
let date = "20231114T221320Z"
func conditionFields() -> [Any] {
    [["bucket": bucket], ["key": key], ["content-type": "application/octet-stream"],
     ["x-goog-algorithm": "GOOG4-RSA-SHA256"], ["x-goog-credential": credential], ["x-goog-date": date],
     ["content-length-range", 1, 3_145_728]]
}
func policy(conditions: [Any]? = nil, expiration: String = "2023-11-14T22:18:20.000Z") throws -> String {
    try JSONSerialization.data(withJSONObject: ["expiration": expiration, "conditions": conditions ?? conditionFields()], options: .sortedKeys).base64EncodedString()
}
func fixture() throws -> GroupsProtoAvatarUploadAttributesBuilder {
    var builder = GroupsProtoAvatarUploadAttributes.builder()
    builder.setKey(key); builder.setCredential(credential); builder.setAlgorithm("GOOG4-RSA-SHA256")
    builder.setDate(date); builder.setPolicy(try policy()); builder.setSignature(String(repeating: "a", count: 512))
    builder.setUploadURL("https://storage.googleapis.com/" + bucket + "/")
    builder.setExpiresAt(1_700_000_300); builder.setMaxContentLength(3_145_728)
    return builder // No ACL: exact proto3 wire behavior.
}
func parsed(_ builder: GroupsProtoAvatarUploadAttributesBuilder, expectedBucket: String = bucket, expectedSigner: String = signer,
    expectedGroupId: Data = group, length: Int = 1, instant: Date = now
) throws -> Upload.CDN0.Form {
    let proto = try GroupsProtoAvatarUploadAttributes(serializedData: builder.buildSerializedData())
    return try Upload.CDN0.Form.parseOwnedGroup(proto: proto, expectedBucket: expectedBucket, expectedSigner: expectedSigner,
        expectedGroupId: expectedGroupId, encryptedLength: length, now: instant)
}
func rejects(_ body: () throws -> Void) {
    do { try body(); preconditionFailure("invalid group avatar form accepted") } catch {}
}
let builder = try fixture()
let proto = try GroupsProtoAvatarUploadAttributes(serializedData: builder.buildSerializedData())
precondition(proto.acl == nil && proto.uploadURL == "https://storage.googleapis.com/" + bucket + "/")
precondition(proto.expiresAt == 1_700_000_300 && proto.maxContentLength == 3_145_728)
let form = try parsed(builder)
precondition(form.ownedDestination?.url.absoluteString == proto.uploadURL)
let multipart = try form.asOrderedDictionary
precondition(multipart.orderedKeys == ["key", "x-goog-algorithm", "x-goog-credential", "x-goog-date", "policy", "x-goog-signature", "content-type"])
precondition(multipart["acl"] == nil && multipart["Content-Type"] == nil && multipart["content-type"] == "application/octet-stream")
precondition(multipart["key"] == key && multipart["policy"] == proto.policy)
_ = try parsed(builder, length: 3_145_728)
print("PASS actual additive protobuf round trip, absent Google ACL, explicit scope and lowercase multipart content-type")

for invalidURL in ["https://storage.googleapis.com/other/", "https://storage.googleapis.com/" + bucket,
    "https://storage.googleapis.com:443/" + bucket + "/", "https://u@storage.googleapis.com/" + bucket + "/",
    "https://storage.googleapis.com/" + bucket + "/?q=1", "https://storage.googleapis.com/" + bucket + "/#f",
    "http://storage.googleapis.com/" + bucket + "/", "https://storage.googleapis.com.evil.invalid/" + bucket + "/"] {
    var invalid = builder; invalid.setUploadURL(invalidURL)
    rejects { _ = try parsed(invalid) }
}
for length in [0, -1, 3_145_729] { rejects { _ = try parsed(builder, length: length) } }
for value in ["other", bucket + "\n", "a/b", "", "-bad", "bad-", "a..b"] {
    rejects { _ = try parsed(builder, expectedBucket: value) }
}
rejects { _ = try parsed(builder, expectedSigner: "other@fixture.iam.gserviceaccount.com") }
rejects { _ = try parsed(builder, expectedGroupId: Data(repeating: 1, count: 32)) }
rejects { _ = try parsed(builder, expectedGroupId: Data(repeating: 0, count: 31)) }
rejects { _ = try parsed(builder, instant: Date(timeIntervalSince1970: 1_700_000_300)) }
rejects { _ = try parsed(builder, instant: Date(timeIntervalSince1970: 1_699_999_994)) }
for value: UInt64 in [0, 1_700_000_000, 1_700_000_306, UInt64.max] {
    var invalid = builder; invalid.setExpiresAt(value); rejects { _ = try parsed(invalid) }
}
for value: UInt32 in [0, 1, 3_145_729] {
    var invalid = builder; invalid.setMaxContentLength(value); rejects { _ = try parsed(invalid) }
}
for invalidKey in [key + "/", key + "==", key.dropLast() + "B", key.replacingOccurrences(of: "groups/", with: "profiles/"), "../other"] {
    var invalid = builder; invalid.setKey(String(invalidKey)); rejects { _ = try parsed(invalid) }
}
print("PASS unsafe endpoints, mismatched bucket/signer/group, noncanonical keys, stale/future expiry and invalid encrypted sizes reject")

for mutation in 0..<7 {
    var invalid = builder
    switch mutation {
    case 0: invalid.setAcl("public-read")
    case 1: invalid.setAlgorithm("AWS4-HMAC-SHA256")
    case 2: invalid.setSignature("not-hex")
    case 3: invalid.setPolicy("invalid")
    case 4: invalid.setPolicy(try policy(expiration: "2023-11-14T22:18:21Z"))
    case 5: invalid.setCredential("other/20231114/auto/storage/goog4_request")
    default: invalid.setDate("20231114T221320Z\n")
    }
    rejects { _ = try parsed(invalid) }
}
for mutation in 0..<6 {
    var conditions = conditionFields()
    switch mutation {
    case 0: conditions.append(["acl": "public-read"])
    case 1: conditions.append(["key": key])
    case 2: conditions[6] = ["content-length-range", true, 3_145_728]
    case 3: conditions[6] = ["content-length-range", 0, 3_145_728]
    case 4: conditions[1] = ["starts-with", "$key", "groups/"]
    default: conditions[2] = ["Content-Type": "application/octet-stream"]
    }
    var invalid = builder; invalid.setPolicy(try policy(conditions: conditions)); rejects { _ = try parsed(invalid) }
}
print("PASS policy expiry/scope, exact conditions, no ACL/starts-with, signer fields and bounded signature shape reject malformed forms")

rejects { _ = try Upload.CDN0.Form.parse(proto: proto) }
// No DependenciesBridge/SSKEnvironment has been installed: failure must precede their access.
do { _ = try await Upload.CDN0.upload(data: Data([1]), uploadForm: form); preconditionFailure("owned form entered CDN0") }
catch Upload.CDN0.Form.ParsingError.ownedGroupRouteUnavailable {}
var legacy = builder
legacy.setUploadURL(""); legacy.setExpiresAt(0); legacy.setMaxContentLength(0)
let google = try Upload.CDN0.Form.parse(proto: legacy.buildInfallibly())
let googleMultipart = try google.asOrderedDictionary
precondition(googleMultipart["content-type"] == "application/octet-stream")
legacy.setAlgorithm("AWS4-HMAC-SHA256")
rejects { _ = try Upload.CDN0.Form.parse(proto: legacy.buildInfallibly()) }
legacy.setAcl("private")
let aws = try Upload.CDN0.Form.parse(proto: legacy.buildInfallibly()).asOrderedDictionary
precondition(aws["acl"] == "private" && aws["x-amz-algorithm"] == "AWS4-HMAC-SHA256")
precondition(aws["Content-Type"] == "application/octet-stream" && aws["content-type"] == nil)
print("PASS owned metadata cannot enter generic parser/upload; AWS ACL and multipart spelling retained; no network or capability release")
print("4 actual-framework group-avatar form contract groups passed")
