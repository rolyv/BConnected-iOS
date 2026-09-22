// Copyright 2026 BConnected contributors. SPDX-License-Identifier: AGPL-3.0-only
// Actual ordinary request factory and Codable wire boundary; no network or credentials fetched.
import Foundation
@testable import SignalServiceKit

SetCurrentAppContext(TestAppContext(), isRunningTests: true)
let db = InMemoryDB()
let readiness = AppReadinessImpl()
let manager = TSAccountManagerImpl(appReadiness: readiness, dateProvider: { Date() },
    databaseChangeObserver: DatabaseChangeObserverImpl(appReadiness: readiness), db: db)
let attributes = AccountAttributes(isManualMessageFetchEnabled: true, registrationId: 23,
    pniRegistrationId: 42, unidentifiedAccessKey: Data(repeating: 1, count: 16).base64EncodedString(),
    unrestrictedUnidentifiedAccess: false, reglockToken: nil,
    registrationRecoveryPassword: "synthetic-recovery-must-not-be-published", encryptedDeviceName: nil,
    discoverableByPhoneNumber: .nobody, capabilities: .init(hasSVRBackups: false))
let factory = AccountAttributesRequestFactory(tsAccountManager: manager)
func body(_ attributes: AccountAttributes) throws -> [String: Any] {
    let request = factory.updatePrimaryDeviceAttributesRequest(attributes, auth: .implicit())
    precondition(request.url.relativeString == "v1/accounts/attributes" && request.method == "PUT")
    guard case .encodable(let value) = request.body else { preconditionFailure("wrong body type") }
    return try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
}
let original = try body(attributes)
precondition(original["recoveryPassword"] == nil && original["registrationId"] as? Int == 23)
precondition(original["pniRegistrationId"] as? Int == 42 && original["fetchesMessages"] as? Bool == true)
precondition(original["discoverableByPhoneNumber"] as? Bool == false)
var cached = original
cached["recoveryPassword"] = "synthetic-decoded-recovery-must-not-be-published"
let decoded = try JSONDecoder().decode(AccountAttributes.self, from: JSONSerialization.data(withJSONObject: cached))
let roundTripped = try body(decoded)
precondition(NSDictionary(dictionary: original).isEqual(to: roundTripped))
db.read {
    precondition(manager.storedServerAuthToken(tx: $0) == nil && manager.localIdentifiers(tx: $0) == nil)
}
print("PASS ordinary account-attribute factory omits supplied and decoded recoveryPassword; other fields preserved; no account credential acquisition")
