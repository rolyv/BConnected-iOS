// Copyright 2026 BConnected contributors. SPDX-License-Identifier: AGPL-3.0-only
// Actual framework accessors use explicit public-only inputs in a standalone test bundle.
// Native signature validation proves the stated public chain, not live server/provider acceptance.
import Foundation
import LibSignalClient
@testable import SignalServiceKit

let info = Bundle.main.infoDictionary!
let supplied = try BConnectedOwnedCryptographicConfiguration(info: info)
let loaded = try TSConstants.loadOwnedCryptographicConfiguration()
precondition(loaded.groupServerPublicParams == supplied.groupServerPublicParams)
precondition(loaded.senderCertificateTrustRoots == supplied.senderCertificateTrustRoots)
precondition(TSConstants.serverPublicParams == supplied.groupServerPublicParams)
precondition(TSConstants.kUDTrustRoots == supplied.senderCertificateTrustRoots)
for constants in [TSConstants.shared, TSConstantsProduction(), TSConstantsStaging()] {
    precondition(constants.serverPublicParams == supplied.groupServerPublicParams)
    precondition(constants.kUDTrustRoots == supplied.senderCertificateTrustRoots)
}
precondition(GroupsV2Protos.serverPublicParams().serialize() == supplied.groupServerPublicParams)
precondition(OWSUDManagerImpl.trustRoots().map { $0.serialize().base64EncodedString() } == supplied.senderCertificateTrustRoots)
var missing = info
missing.removeValue(forKey: "BConnectedSenderCertificateTrustRootsBase64")
do { _ = try BConnectedOwnedCryptographicConfiguration(info: missing); preconditionFailure("sender root inferred") }
catch BConnectedTransportError.invalidOwnedConfiguration {}
missing = info
missing.removeValue(forKey: "BConnectedGroupPublicParamsBase64")
do { _ = try BConnectedOwnedCryptographicConfiguration(info: missing); preconditionFailure("upstream params inferred") }
catch BConnectedTransportError.invalidOwnedConfiguration {}
if let encoded = info["BConnectedProbeServerCertificateBase64"] as? String {
    let bytes = Data(base64Encoded: encoded)!
    let certificate = try ServerCertificate(bytes)
    let root = try PublicKey(Data(base64Encoded: supplied.senderCertificateTrustRoots[0])!)
    precondition(certificate.serialize() == bytes)
    precondition(certificate.keyId == (info["BConnectedProbeServerCertificateId"] as! NSNumber).uint32Value)
    let verified = try root.verifySignature(message: certificate.certificateBytes, signature: certificate.signatureBytes)
    precondition(verified)
    var tampered = certificate.signatureBytes; tampered[0] ^= 1
    let tamperedVerified = try root.verifySignature(message: certificate.certificateBytes, signature: tampered)
    precondition(!tamperedVerified)
    print("PASS supplied server signer certificate parses natively, matches key ID and verifies under the independent public sender trust root; tampered signature rejects")
} else {
    print("NOTE sender root is synthetic fixture only")
}
print("PASS explicit public authorities reach actual TSConstants, GroupsV2Protos and UD consumers; absent authorities reject without fallback")

var publicationInfo = info
publicationInfo["BConnectedAccountPublicationOrigin"] = "https://publication.example.invalid"
publicationInfo["BConnectedAccountPublicationTrust"] = "system"
_ = try BConnectedPublicationConfiguration(info: publicationInfo)
for field in ["BConnectedAccountPublicationOrigin", "BConnectedAccountPublicationTrust", "BConnectedGroupPublicParamsBase64", "BConnectedSenderCertificateTrustRootsBase64"] {
    var incomplete = publicationInfo; incomplete.removeValue(forKey: field)
    do { _ = try BConnectedPublicationConfiguration(info: incomplete); preconditionFailure("publication config inferred") }
    catch {}
}
var invalid = publicationInfo
invalid["BConnectedAccountPublicationCertificateDERBase64"] = "unexpected"
do { _ = try BConnectedPublicationConfiguration(info: invalid); preconditionFailure("conflicting publication TLS inputs accepted") }
catch {}
print("PASS actual publication composition requires its own HTTPS origin, explicit system trust and both native public authorities; missing or conflicting inputs reject")
