//
// Copyright 2023 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import LibSignalClient

// MARK: -

public protocol SgxWebsocketConnectionFactory {
    var transportCapabilities: BConnectedTransportCapabilities { get }

    /// Connect to an SgxClient-conformant server via websocket and perform the initial handshake.
    ///
    /// - Parameters:
    ///   - queue: The queue to use.
    /// - Returns:
    ///     A Promise for an established connection. If the Promise doesn’t
    ///     resolve to an error, the caller is responsible for ensuring the
    ///     returned connection is properly disconnected.
    func connectAndPerformHandshake<Configurator: SgxWebsocketConfigurator>(
        configurator: Configurator,
    ) async throws -> SgxWebsocketConnection<Configurator>
}

final class SgxWebsocketConnectionFactoryImpl: SgxWebsocketConnectionFactory {

    private let websocketFactory: WebSocketFactory
    let transportCapabilities: BConnectedTransportCapabilities

    init(websocketFactory: WebSocketFactory, transportCapabilities: BConnectedTransportCapabilities) {
        self.websocketFactory = websocketFactory
        self.transportCapabilities = transportCapabilities
    }

    func connectAndPerformHandshake<Configurator: SgxWebsocketConfigurator>(
        configurator: Configurator,
    ) async throws -> SgxWebsocketConnection<Configurator> {
        try transportCapabilities.require(Configurator.signalServiceType.requiredHTTPCapability)
        let websocketFactory = self.websocketFactory
        let auth = try await configurator.fetchAuth()
        return try await SgxWebsocketConnectionImpl<Configurator>.connectAndPerformHandshake(
            configurator: configurator,
            auth: auth,
            websocketFactory: websocketFactory,
        )
    }
}
