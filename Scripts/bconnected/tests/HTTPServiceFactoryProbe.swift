// Copyright 2026 BConnected contributors. SPDX-License-Identifier: AGPL-3.0-only
// Actual compiled framework factories. No AppSetup, service environment, sockets or credentials.
import Foundation
import LibSignalClient
@testable import SignalServiceKit

func denied(_ capability: BConnectedTransportCapability, _ action: () throws -> Void) {
    do { try action(); preconditionFailure("Unexpected available HTTP service") }
    catch { precondition((error as? BConnectedTransportError) == .unavailable(capability)) }
}
let transport = try BConnectedOwnedTransportConfiguration(info: [
    "BConnectedMessagingHost": "service.example.invalid", "BConnectedMessagingPort": "443", "BConnectedMessagingTrust": "system",
], userAgent: "BConnected synthetic factory probe").makeTransport()
let service = OWSSignalService(libsignalNet: transport)
denied(.mainServiceHTTP) { _ = try service.urlSessionForMainSignalService() }
denied(.storageService) { _ = try service.urlSessionForStorageService() }
denied(.updates) { _ = try service.urlSessionForUpdates() }
denied(.updates) { _ = try service.urlSessionForUpdates2() }
for type: SignalServiceType in [.mainSignalService, .storageService, .updates, .updates2, .svr2] {
    // Do not map TSConstants: the fixture identifies the requested service explicitly.
    let info = SignalServiceInfo(baseUrl: URL(string: "https://service.example.invalid")!, assumesHTTP3Capable: false,
        censorshipCircumventionSupported: true, censorshipCircumventionPathPrefix: "test",
        shouldUseSignalCertificate: true, shouldHandleRemoteDeprecation: false, type: type)
    denied(type.requiredHTTPCapability) { _ = try service.buildUrlEndpoint(for: info) }
    let endpoint = OWSURLSessionEndpoint(baseUrl: info.baseUrl, frontingInfo: nil, securityPolicy: .systemDefault, extraHeaders: [:])
    denied(type.requiredHTTPCapability) { _ = try service.buildUrlSession(for: info, endpoint: endpoint, configuration: .ephemeral) }
}
print("PASS actual HTTP factories deny all unconfigured routes before TSConstants, DB or URLSession access")
let request = WebSocketRequest(signalService: .svr2, urlPath: "/test", urlQueryItems: nil, extraHeaders: [:])
precondition(SSKWebSocketNative(request: request, signalService: service, callbackScheduler: DispatchQueue.global()) == nil)
print("PASS direct unsupported websocket factory fails before endpoint construction")
struct ForbiddenConfigurator: SgxWebsocketConfigurator {
    typealias Request = SVR2Proto_Request
    typealias Response = SVR2Proto_Response
    typealias Client = Svr2Client
    var mrenclave: MrEnclave { fatalError("must not inspect enclave") }
    static var signalServiceType: SignalServiceType { .svr2 }
    static func websocketUrlPath(mrenclaveString: String) -> String { fatalError("must not build route") }
    func fetchAuth() async throws -> RemoteAttestationAuth { fatalError("must not acquire credentials") }
    static func client(mrenclave: MrEnclave, attestationMessage: Data, currentDate: Date) throws -> Svr2Client { fatalError("must not start attestation") }
}
let sgx = SgxWebsocketConnectionFactoryImpl(websocketFactory: WebSocketFactoryMock(), transportCapabilities: transport.capabilities)
do {
    _ = try await sgx.connectAndPerformHandshake(configurator: ForbiddenConfigurator())
    preconditionFailure("Unsupported recovery succeeded")
} catch { precondition((error as? BConnectedTransportError) == .unavailable(.secureValueRecovery)) }
print("PASS actual SGX factory rejects recovery before auth acquisition or socket creation")
print("3 native service factory probes passed; no app lifecycle or provider effects")
