// Copyright 2026 BConnected contributors. SPDX-License-Identifier: AGPL-3.0-only

public import LibSignalClient

/// Keeps capability checks ahead of ephemeral-key preparation and native socket creation.
public struct BConnectedProvisioningConsumer {
    private let transport: any BConnectedChatTransport

    public init(transport: any BConnectedChatTransport) {
        self.transport = transport
    }

    public func connect<Prepared>(
        prepare: () throws -> Prepared
    ) async throws -> (prepared: Prepared, connection: ProvisioningConnection) {
        try transport.capabilities.require(.provisioning)
        try Task.checkCancellation()
        let prepared = try prepare()
        try Task.checkCancellation()
        let connection = try await transport.connectProvisioning()
        return (prepared, connection)
    }
}
