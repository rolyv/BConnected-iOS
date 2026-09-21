//
// Copyright 2018 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import LibSignalClient

public protocol NetworkManagerProtocol {
    func asyncRequestImpl(
        _ request: TSRequest,
        retryPolicy: NetworkManager.RetryPolicy,
    ) async throws -> HTTPResponse
}

extension NetworkManagerProtocol {
    public func asyncRequest(
        _ request: TSRequest,
        retryPolicy: NetworkManager.RetryPolicy = .dont,
    ) async throws -> HTTPResponse {
        return try await asyncRequestImpl(request, retryPolicy: retryPolicy)
    }
}

// A class used for making HTTP requests against the main service.
public class NetworkManager: NetworkManagerProtocol {
    private let appReadiness: AppReadiness
    private let reachabilityDidChangeObserver: Task<Void, Never>?
    private var chatConnectionManager: ChatConnectionManager {
        // TODO: Fix circular dependencies.
        DependenciesBridge.shared.chatConnectionManager
    }

    public let libsignalNet: (any BConnectedChatTransport)?

    public init(appReadiness: AppReadiness, libsignalNet: (any BConnectedChatTransport)?) {
        self.appReadiness = appReadiness
        self.libsignalNet = libsignalNet
        if let libsignalNet {
            self.reachabilityDidChangeObserver = Task {
                for await _ in NotificationCenter.default.notifications(named: SSKReachability.owsReachabilityDidChange) {
                    do {
                        try BConnectedNetworkConfiguration(transport: libsignalNet).networkDidChange(
                            inAppProxyEnabled: SignalProxy.isEnabled,
                            systemProxy: { ProxyConfig.fromCFNetwork(rejectUnsupported: !libsignalNet.capabilities.allows(.proxy)) }
                        )
                    } catch {
                        Logger.warn("Transport rejected network configuration: \(error)")
                    }
                }
            }

            self.updateProxySettingsAfterConfigurationChange()
            Logger.info("Initialized chat transport network observer.")
            appReadiness.runNowOrWhenAppDidBecomeReadyAsync {
                // We did this once already, but doing it properly depends on RemoteConfig.
                self.updateProxySettingsAfterConfigurationChange()
            }
        } else {
            self.reachabilityDidChangeObserver = nil
        }

    }

    deinit {
        if let reachabilityDidChangeObserver {
            reachabilityDidChangeObserver.cancel()
        }
    }

    // MARK: -

    func requireSignalProxySupport() throws {
        guard let libsignalNet else { return } // Explicit no-network test injection.
        try BConnectedNetworkConfiguration(transport: libsignalNet).requireProxySupport()
    }

    func setSignalProxy(host: String, port: UInt16?) throws {
        guard let libsignalNet else { return }
        try BConnectedNetworkConfiguration(transport: libsignalNet).setSignalProxy(host: host, port: port)
    }

    func resetLibsignalNetProxySettings() throws {
        guard let libsignalNet else { return }
        try BConnectedNetworkConfiguration(transport: libsignalNet).resetProxy(
            inAppProxyEnabled: SignalProxy.isEnabled,
            systemProxy: { ProxyConfig.fromCFNetwork(rejectUnsupported: !libsignalNet.capabilities.allows(.proxy)) }
        )
    }

    private func updateProxySettingsAfterConfigurationChange() {
        do { try resetLibsignalNetProxySettings() }
        catch { Logger.warn("Transport rejected proxy configuration: \(error)") }
    }

    // MARK: -

    public struct RetryPolicy {
        public struct RetryOn: OptionSet {
            public let rawValue: Int

            public init(rawValue: Int) {
                self.rawValue = rawValue
            }

            static let fiveXXResponse: RetryOn = .init(rawValue: 1 << 0)
            static let networkFailureOrTimeout: RetryOn = .init(rawValue: 1 << 1)
        }

        public let retryOn: [RetryOn]
        public let maxAttempts: Int

        public init(
            retryOn: [RetryOn],
            maxAttempts: Int,
        ) {
            self.retryOn = retryOn
            self.maxAttempts = maxAttempts
        }

        public static let dont: RetryPolicy = RetryPolicy(
            retryOn: [],
            maxAttempts: 1,
        )

        public static let hopefullyRecoverable: RetryPolicy = RetryPolicy(
            retryOn: [.fiveXXResponse, .networkFailureOrTimeout],
            maxAttempts: 3,
        )
    }

    public func asyncRequestImpl(
        _ request: TSRequest,
        retryPolicy: RetryPolicy,
    ) async throws -> HTTPResponse {
        return try await Retry.performWithBackoff(
            maxAttempts: retryPolicy.maxAttempts,
            isRetryable: { error -> Bool in
                if
                    error.isNetworkFailureOrTimeout,
                    retryPolicy.retryOn.contains(.networkFailureOrTimeout)
                {
                    return true
                } else if
                    error.is5xxServiceResponse,
                    retryPolicy.retryOn.contains(.fiveXXResponse)
                {
                    return true
                }

                return false
            },
            block: { try await _asyncRequest(request) },
        )
    }

    private func _asyncRequest(_ request: TSRequest) async throws -> HTTPResponse {
        if let libsignalNet {
            try BConnectedNetworkConfiguration(transport: libsignalNet).requireRequestedProxySupported(
                inAppProxyEnabled: SignalProxy.isEnabled,
                systemProxy: { ProxyConfig.fromCFNetwork(rejectUnsupported: !libsignalNet.capabilities.allows(.proxy)) }
            )
        }
        do {
            return try await chatConnectionManager.makeRequest(request)
        } catch {
            if case OWSHTTPError.wrappedFailure(URLError.cancelled) = error {
                try Task.checkCancellation()
            }
            throw error
        }
    }
}

// MARK: -

private enum ProxyConfig {
    static func fromCFNetwork(rejectUnsupported: Bool) -> BConnectedSystemProxy? {
        let chatURL = URL(string: TSConstants.mainServiceURL)!
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() else {
            return nil
        }
        let proxies = CFNetworkCopyProxiesForURL(chatURL as CFURL, settings).takeRetainedValue() as! [NSDictionary]

        return BConnectedSystemProxyParser.firstProxy(in: proxies, rejectUnsupported: rejectUnsupported)
    }
}

// MARK: -

#if TESTABLE_BUILD

public class OWSFakeNetworkManager: NetworkManager {

    override public func asyncRequestImpl(
        _ request: TSRequest,
        retryPolicy: RetryPolicy,
    ) async throws -> HTTPResponse {
        Logger.info("Ignoring request: \(request)")
        // Never resolve.
        return try await withUnsafeThrowingContinuation { (_ continuation: UnsafeContinuation<HTTPResponse, any Error>) -> Void in }
    }
}

class MockNetworkManager: NetworkManagerProtocol {
    var asyncRequestHandlers = [(TSRequest, NetworkManager.RetryPolicy) async throws -> HTTPResponse]()
    func asyncRequestImpl(
        _ request: TSRequest,
        retryPolicy: NetworkManager.RetryPolicy,
    ) async throws -> HTTPResponse {
        return try await asyncRequestHandlers.removeFirst()(request, retryPolicy)
    }
}

#endif
