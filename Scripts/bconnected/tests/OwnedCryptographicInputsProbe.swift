// Copyright 2026 BConnected contributors. SPDX-License-Identifier: AGPL-3.0-only
// Actual framework accessors use an explicit public-params input and a SYNTHETIC public sender
// root in this standalone test bundle. No production sender authority or provider acceptance.
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
print("PASS explicit public group parameters and synthetic sender root reach actual TSConstants, GroupsV2Protos and UD consumers; absent authorities reject without fallback")
