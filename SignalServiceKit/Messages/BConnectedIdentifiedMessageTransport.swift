// Copyright 2026 BConnected contributors. SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import LibSignalClient

/// The owned server implements the guarded REST message API over authenticated chat.
/// Libsignal's newer typed message API uses a gRPC method that this server does not implement.
enum BConnectedIdentifiedMessageTransport {
    private struct Payload: Encodable {
        let messages: [DeviceMessage]
        let timestamp: UInt64
        let online: Bool
        let urgent: Bool
    }

    private struct Accepted: Decodable { let needsSync: Bool }
    private struct Mismatch: Decodable { let missingDevices: [UInt32]; let extraDevices: [UInt32] }
    private struct Stale: Decodable { let staleDevices: [UInt32] }

    static func send(
        to destination: ServiceId,
        messages: [DeviceMessage],
        timestamp: UInt64,
        online: Bool,
        urgent: Bool,
        request: (TSRequest) async throws -> HTTPResponse
    ) async throws {
        guard destination is Aci, messages.count == 1,
              case .unsealed(let message) = messages[0], message.deviceId == .primary,
              message.registrationId > 0, message.registrationId <= 0x3fff,
              [.whisper, .preKey, .plaintext].contains(message.contents.messageType) else {
            throw BConnectedTransportError.unavailable(.authenticatedChat)
        }
        var outgoing = TSRequest(
            url: URL(string: "v1/messages/\(destination.serviceIdString)")!,
            method: "PUT",
            body: .encodable(Payload(messages: messages, timestamp: timestamp, online: online, urgent: urgent))
        )
        outgoing.auth = .identified(.implicit())
        outgoing.maxResponseSize = 4096

        let response: HTTPResponse
        do {
            response = try await request(outgoing)
        } catch let error as OWSHTTPError {
            throw translatedError(status: error.responseStatusCode, data: error.responseBodyData,
                                  destination: destination, fallback: error)
        }
        guard response.responseStatusCode == 200 else {
            throw translatedError(status: response.responseStatusCode, data: response.responseBodyData,
                                  destination: destination, fallback: response.asError())
        }
        guard let data = response.responseBodyData, data.count <= 4096,
              let accepted = try? JSONDecoder().decode(Accepted.self, from: data), !accepted.needsSync else {
            throw OWSHTTPError.networkFailure(.invalidResponseStatus)
        }
    }

    /// Preserve the existing sender's one-retry reconciliation for changed recipient sessions.
    /// Malformed or secondary-device responses cannot mutate the local recipient/session state.
    private static func translatedError(
        status: Int, data: Data?, destination: ServiceId, fallback: OWSHTTPError
    ) -> any Error {
        if status == 404 { return SignalError.serviceIdNotFound("Recipient unavailable") }
        guard let data, data.count <= 4096 else { return fallback }
        let decoder = JSONDecoder()
        if status == 409, let mismatch = try? decoder.decode(Mismatch.self, from: data),
           validPrimaryList(mismatch.missingDevices), validPrimaryList(mismatch.extraDevices),
           !mismatch.missingDevices.isEmpty || !mismatch.extraDevices.isEmpty,
           Set(mismatch.missingDevices).isDisjoint(with: mismatch.extraDevices) {
            return SignalError.mismatchedDevices(entries: [MismatchedDeviceEntry(
                account: destination, missingDevices: mismatch.missingDevices, extraDevices: mismatch.extraDevices
            )], message: "Recipient devices changed")
        }
        if status == 410, let stale = try? decoder.decode(Stale.self, from: data), stale.staleDevices == [1] {
            return SignalError.mismatchedDevices(entries: [MismatchedDeviceEntry(
                account: destination, staleDevices: stale.staleDevices
            )], message: "Recipient registration changed")
        }
        return fallback
    }

    private static func validPrimaryList(_ devices: [UInt32]) -> Bool {
        devices.isEmpty || devices == [1]
    }
}
