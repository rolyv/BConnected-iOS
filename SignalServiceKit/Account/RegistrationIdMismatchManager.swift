//
// Copyright 2025 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import LibSignalClient

public protocol RegistrationIdMismatchManager {
    func validateRegistrationIds() async
}

public class RegistrationIdMismatchManagerImpl: RegistrationIdMismatchManager {

    private enum Constants {
        static let hasRecordedSuspectedIssue = "hasRecordedSuspectedIssue"
        static let haveRegistrationIdsBeenChecked = "haveRegistrationIdsBeenChecked"
    }

    private let db: DB
    private let kvStore = NewKeyValueStore(collection: "RegistrationIdMismatchManagerImpl")
    private let tsAccountManager: TSAccountManager
    private let fetchRegistrationId: (ServiceId) async throws -> UInt32

    public convenience init(db: DB, tsAccountManager: TSAccountManager, udManager: OWSUDManager) {
        self.init(db: db, tsAccountManager: tsAccountManager) { serviceId in
            try await Self.fetchRegistrationId(
                serviceId: serviceId,
                db: db,
                tsAccountManager: tsAccountManager,
                udManager: udManager,
            )
        }
    }

    /// Inject only the remote lookup; validation and its durable completion marker remain shared.
    init(db: DB, tsAccountManager: TSAccountManager, fetchRegistrationId: @escaping (ServiceId) async throws -> UInt32) {
        self.db = db
        self.tsAccountManager = tsAccountManager
        self.fetchRegistrationId = fetchRegistrationId
    }

    public func validateRegistrationIds() async {
        guard
            !db.read(block: {
                kvStore.fetchValue(Bool.self, forKey: Constants.haveRegistrationIdsBeenChecked, tx: $0) ?? false
            })
        else {
            return
        }

        guard
            let registeredState = db.read(block: { tx in
                return try? tsAccountManager.registeredState(tx: tx)
            })
        else {
            Logger.warn("Attempting to check registrationId while unregistered.")
            return
        }

        do {
            // Check ACI
            try await _checkRegistrationIdMatches(identity: .aci, serviceId: registeredState.localIdentifiers.aci)

            // Check PNI
            if let pni = registeredState.localIdentifiers.pni {
                try await _checkRegistrationIdMatches(identity: .pni, serviceId: pni)
            } else {
                owsFailDebug("Missing PNI during registrationId check")
                return
            }

            await db.awaitableWrite {
                kvStore.writeValue(true, forKey: Constants.haveRegistrationIdsBeenChecked, tx: $0)
            }
        } catch where error is BConnectedTransportError || error.isNetworkFailureOrTimeout || error.is5xxServiceResponse {
            // An unavailable lookup is not evidence that either registration ID matches.
            // Leave the durable marker unchecked so a later launch can try again.
            Logger.warn("Deferring registration ID validation because the prekey service is unavailable.")
        } catch {
            owsFailDebug("Failed to validate registration IDs: \(error)")
            return
        }
    }

    private static func fetchRegistrationId(
        serviceId: ServiceId,
        db: DB,
        tsAccountManager: TSAccountManager,
        udManager: OWSUDManager,
    ) async throws -> UInt32 {
        let (udAccess, deviceId) = db.read { tx in (
            (serviceId as? Aci).flatMap { udManager.udAccess(for: $0, tx: tx) },
            tsAccountManager.storedDeviceId(tx: tx),
        ) }

        // Fetch a key bundle for yourself.
        let requestMaker = RequestMaker(
            label: "RegistrationId Prekey Fetch",
            serviceId: serviceId,
            canUseStoryAuth: false,
            accessKey: udAccess,
            endorsement: nil,
            authedAccount: .implicit,
            options: [.allowIdentifiedFallback],
        )

        let result = try await requestMaker.makeRequest {
            return OWSRequestFactory.recipientPreKeyRequest(
                serviceId: serviceId,
                deviceId: deviceId.description,
                auth: $0,
            )
        }

        guard let responseData = result.response.responseBodyData else {
            throw OWSAssertionError("Prekey fetch missing response object.")
        }
        guard let bundle = try? JSONDecoder().decode(SignalServiceKit.PreKeyBundle.self, from: responseData) else {
            throw OWSAssertionError("Prekey fetch returned an invalid bundle.")
        }
        guard let registrationId = bundle.devices.first?.registrationId else {
            throw OWSAssertionError("Prekey fetch missing registration Id")
        }
        return registrationId
    }

    private func _checkRegistrationIdMatches(identity: OWSIdentity, serviceId: ServiceId) async throws {
        let registrationId = try await fetchRegistrationId(serviceId)

        if let localRegistrationId = db.read(block: { tsAccountManager.getRegistrationId(for: identity, tx: $0) }) {
            // Fetch local registration Id
            // Check if it's out of sync.
            if localRegistrationId == registrationId {
                // Everything matches, return
                Logger.info("\(identity) registrationId matches the server's understanding.")
                return
            }
            Logger.warn("\(identity) registrationId out of sync")
        } else {
            Logger.warn("\(identity) missing registrationId.")
        }

        await db.awaitableWrite {
            // update local state to match remote
            Logger.warn("Updating local \(identity) registrationId to match remote.")
            self.tsAccountManager.setRegistrationId(registrationId, for: identity, tx: $0)
            self.kvStore.writeValue(true, forKey: Constants.hasRecordedSuspectedIssue, tx: $0)
        }
    }
}
