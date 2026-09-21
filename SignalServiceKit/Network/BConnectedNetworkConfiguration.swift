// Copyright 2026 BConnected contributors. SPDX-License-Identifier: AGPL-3.0-only

import LibSignalClient
import CFNetwork
import Foundation

/// Optional legacy controls, deliberately absent from the owned chat transport protocol.
protocol BConnectedNativeProxyControl: AnyObject {
    func setProxy(scheme: String, host: String, port: UInt16?, username: String?, password: String?) throws
    func setProxy(host: String, port: UInt16?) throws
    func clearProxy()
}

extension Net: BConnectedNativeProxyControl {}

struct BConnectedSystemProxy {
    let scheme: String
    let host: String
    let port: UInt16?
    let username: String?
    let password: String?
}

/// NetworkManager's configuration boundary. This does not gate other, independent consumers.
struct BConnectedNetworkConfiguration {
    let transport: any BConnectedChatTransport

    func requireProxySupport() throws {
        try transport.capabilities.require(.proxy)
        guard transport is any BConnectedNativeProxyControl else {
            throw BConnectedTransportError.invalidOwnedConfiguration
        }
    }

    func setSignalProxy(host: String, port: UInt16?) throws {
        try requireProxySupport()
        try (transport as! any BConnectedNativeProxyControl).setProxy(host: host, port: port)
    }

    func requireRequestedProxySupported(inAppProxyEnabled: Bool, systemProxy: () -> BConnectedSystemProxy?) throws {
        if inAppProxyEnabled || systemProxy() != nil {
            try requireProxySupport()
        }
    }

    func resetProxy(inAppProxyEnabled: Bool, systemProxy: () -> BConnectedSystemProxy?) throws {
        if inAppProxyEnabled {
            try requireProxySupport()
            return // SignalProxy owns the actual in-app configuration.
        }
        if let proxy = systemProxy() {
            try requireProxySupport()
            let control = transport as! any BConnectedNativeProxyControl
            do {
                try control.setProxy(scheme: proxy.scheme, host: proxy.host, port: proxy.port,
                                     username: proxy.username, password: proxy.password)
            } catch {
                // Preserve the explicit legacy system-proxy policy. Owned transports never
                // reach this branch: unsupported proxy requests fail before control acquisition.
                control.clearProxy()
            }
        } else if transport.capabilities.allows(.proxy) {
            try requireProxySupport()
            (transport as! any BConnectedNativeProxyControl).clearProxy()
        }
        // A chat-only transport without a requested proxy needs no proxy operation at all.
    }

    func networkDidChange(inAppProxyEnabled: Bool, systemProxy: () -> BConnectedSystemProxy?) throws {
        try transport.capabilities.require(.networkChange)
        try resetProxy(inAppProxyEnabled: inAppProxyEnabled, systemProxy: systemProxy)
        try transport.networkDidChange()
    }
}

/// Pure parsing of CFNetwork's ordered candidates; never fetches a PAC URL or executes JavaScript.
enum BConnectedSystemProxyParser {
    // A sentinel for requested routing the legacy parser cannot represent. It is only
    // returned for transports that reject proxies before inspecting these fields.
    private static let unsupportedConfiguration = BConnectedSystemProxy(
        scheme: "unsupported", host: "", port: nil, username: nil, password: nil
    )

    static func firstProxy(in proxies: [NSDictionary], rejectUnsupported: Bool) -> BConnectedSystemProxy? {
        for proxyConfig in proxies {
            switch proxyConfig[kCFProxyTypeKey] as! NSObject? {
            case kCFProxyTypeNone:
                // CFNetworkCopyProxiesForURL returns a list of proxies to try in order,
                // and that can include "try a direct connection".
                // But libsignal only supports one global proxy setting,
                // so if we get told to try a direct connection, that's what we'll do.
                return nil
            case kCFProxyTypeHTTP:
                return BConnectedSystemProxy(
                    scheme: "http",
                    host: proxyConfig[kCFProxyHostNameKey] as! String,
                    port: proxyConfig[kCFProxyPortNumberKey] as! UInt16?,
                    username: proxyConfig[kCFProxyUsernameKey] as! String?,
                    password: proxyConfig[kCFProxyPasswordKey] as! String?,
                )
            case kCFProxyTypeHTTPS:
                // This seems to mean "HTTP proxy for HTTPS connections" rather than "proxy that itself uses TLS".
                // Leave room for the latter interpretation if the port number is traditionally HTTPS.
                let port = proxyConfig[kCFProxyPortNumberKey] as! UInt16?
                return BConnectedSystemProxy(
                    scheme: (port == 443 || port == 8443) ? "https" : "http",
                    host: proxyConfig[kCFProxyHostNameKey] as! String,
                    port: port,
                    username: proxyConfig[kCFProxyUsernameKey] as! String?,
                    password: proxyConfig[kCFProxyPasswordKey] as! String?,
                )
            case kCFProxyTypeSOCKS:
                // iOS doesn't distinguish between SOCKS4 and SOCKS5. Defer to libsignal's default.
                return BConnectedSystemProxy(
                    scheme: "socks",
                    host: proxyConfig[kCFProxyHostNameKey] as! String,
                    port: proxyConfig[kCFProxyPortNumberKey] as! UInt16?,
                    username: proxyConfig[kCFProxyUsernameKey] as! String?,
                    password: proxyConfig[kCFProxyPasswordKey] as! String?,
                )
            case kCFProxyTypeAutoConfigurationJavaScript, kCFProxyTypeAutoConfigurationURL:
                // CFNetwork provides ways to execute these, but they're not something that can be done synchronously.
                // PAC files are rare, though; we can come back to this if it turns out to be used in practice.
                if rejectUnsupported { return unsupportedConfiguration }
                // Legacy mode skips unsupported PAC routing.
                continue
            case kCFProxyTypeFTP:
                // Not relevant for an HTTPS request (honestly, it should never be returned in the first place)
                continue
            case _?:
                if rejectUnsupported { return unsupportedConfiguration }
                // Legacy mode skips unknown routing.
                continue
            case nil:
                if rejectUnsupported { return unsupportedConfiguration }
                // Legacy mode skips malformed candidates.
                continue
            }
        }

        return nil
    }
}
