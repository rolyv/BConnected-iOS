// Copyright 2026 BConnected contributors. SPDX-License-Identifier: AGPL-3.0-only

public import Foundation

/// The caller must supply the current registered primary account credentials explicitly.
/// This value is transient and is never sourced from a pending enrollment record.
public struct BConnectedPrimaryRecipientCredentials: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    fileprivate let aci: String
    fileprivate let password: String
    fileprivate let userAgent: String
    fileprivate let signalAgent: String

    public init(aci: String, password: String, deviceId: Int, userAgent: String, signalAgent: String) throws {
        _ = try BConnectedEnrollmentWire.uuid(aci)
        guard deviceId == 1, try BConnectedEnrollmentWire.base64(password).count == 32 else {
            throw BConnectedEnrollmentError.invalidInput
        }
        _ = try BConnectedEnrollmentWire.metadata(userAgent, limit: 512)
        _ = try BConnectedEnrollmentWire.metadata(signalAgent, limit: 256)
        self.aci = aci
        self.password = password
        self.userAgent = userAgent
        self.signalAgent = signalAgent
    }

    public var description: String { "BConnectedPrimaryRecipientCredentials(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }

    func authenticate(_ request: inout URLRequest) {
        request.setValue("Basic " + Data((aci + ":" + password).utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(signalAgent, forHTTPHeaderField: "X-Signal-Agent")
    }
}

public struct BConnectedRecipient: Equatable, Sendable {
    public let aci: String
    public let deviceId: Int
}

/// Performs one explicit shared-ACI lookup. It never searches by phone number or discovers contacts.
public final class BConnectedRecipientLookupClient {
    private let http: any BConnectedOwnedHTTPSending

    public convenience init() {
        self.init(http: BConnectedOwnedHTTP(responseMode: .enrollmentJSON))
    }

    init(http: any BConnectedOwnedHTTPSending) {
        self.http = http
    }

    public func request(recipientACI: String, credentials: BConnectedPrimaryRecipientCredentials,
                        configuration: BConnectedPublicationConfiguration) throws -> URLRequest {
        _ = try BConnectedEnrollmentWire.uuid(recipientACI)
        var components = URLComponents(url: configuration.origin, resolvingAgainstBaseURL: false)!
        components.path = "/v1/bconnected/recipients/\(recipientACI)"
        var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("Basic " + Data((credentials.aci + ":" + credentials.password).utf8).base64EncodedString(),
                         forHTTPHeaderField: "Authorization")
        request.setValue(credentials.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(credentials.signalAgent, forHTTPHeaderField: "X-Signal-Agent")
        return request
    }

    public func lookup(recipientACI: String, credentials: BConnectedPrimaryRecipientCredentials,
                       configuration: BConnectedPublicationConfiguration) async throws -> BConnectedRecipient {
        let request = try request(recipientACI: recipientACI, credentials: credentials, configuration: configuration)
        let (data, status) = try await http.send(request)
        try Task.checkCancellation()
        return try Self.validateResponse(data, status: status, requestedACI: recipientACI)
    }

    /// Validates the complete response contract without creating account or membership authority.
    public static func validateResponse(_ data: Data, status: Int, requestedACI: String) throws -> BConnectedRecipient {
        do {
            guard status == 200 else { throw BConnectedEnrollmentError.invalidResponse }
            let expectedACI = try BConnectedEnrollmentWire.uuid(requestedACI)
            let response = try BConnectedEnrollmentWire.object(data)
            let fields = try BConnectedEnrollmentWire.fields(response, required: ["aci", "deviceId"])
            let aci = try BConnectedEnrollmentWire.uuid(fields["aci"])
            guard aci == expectedACI, try BConnectedEnrollmentWire.integer(fields["deviceId"]) == 1 else {
                throw BConnectedEnrollmentError.invalidResponse
            }
            return BConnectedRecipient(aci: aci, deviceId: 1)
        } catch {
            throw BConnectedEnrollmentError.invalidResponse
        }
    }
}
