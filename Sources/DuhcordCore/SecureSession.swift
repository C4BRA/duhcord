import Foundation
import os
@preconcurrency import CoreFoundation
@preconcurrency import Security

/// The URLSessions Duhcord uses. `shared` talks to Discord and exists to make sure the token can't leave
/// for anywhere but Discord:
///
/// - Connections are only allowed to Discord's own hosts. Anything else is cancelled before TLS completes.
/// - Certificates must chain to one of Apple's built-in root certificates. Roots added by the user or an
///   administrator (the way corporate proxies and interception tools read TLS traffic) are not trusted.
/// - Redirects are refused, because URLSession would otherwise carry the Authorization header to the new host.
///
/// `updates` is a separate session for the updater: GitHub release hosts only, never the token, and redirects
/// are followed only between those hosts (GitHub serves release files from a second domain).
public final class SecureSession: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    public static let shared = SecureSession(isAllowed: { SecureSession.isAllowed(host: $0) }, followsRedirects: false)
    public static let updates = SecureSession(isAllowed: { SecureSession.isUpdateHost($0) }, followsRedirects: true)
    /// Images, GIFs and video streams: Discord's image proxies and file CDN, never the token, no redirects.
    /// One session for all media, so connections to those hosts are shared rather than opened twice.
    public static let media = SecureSession(isAllowed: { MediaRequest.isAllowedImageHost($0) }, followsRedirects: false)
    /// The voice helper's connection to Discord's voice servers. Never carries the account token.
    public static let voice = SecureSession(isAllowed: { SecureSession.isVoiceHost($0) }, followsRedirects: false)

    private let hostPolicy: @Sendable (String?) -> Bool
    private let followsRedirects: Bool
    private let sessionLock = OSAllocatedUnfairLock<URLSession?>(initialState: nil)

    private init(isAllowed: @escaping @Sendable (String?) -> Bool, followsRedirects: Bool) {
        hostPolicy = isAllowed
        self.followsRedirects = followsRedirects
        super.init()
    }

    public var session: URLSession {
        sessionLock.withLock { stored in
            if let stored { return stored }
            let config = URLSessionConfiguration.ephemeral
            // Nothing about our traffic is written to disk: no cookies, no cache.
            config.httpCookieStorage = nil
            config.httpShouldSetCookies = false
            config.urlCache = nil
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            config.tlsMinimumSupportedProtocolVersion = .TLSv12
            let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
            stored = session
            return session
        }
    }

    /// Hosts Duhcord may connect to.
    public static func isAllowed(host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "discord.com" || host == "discord.gg" || host.hasSuffix(".discord.gg")
    }

    /// Discord's voice servers (the endpoint in VOICE_SERVER_UPDATE).
    public static func isVoiceHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host.hasSuffix(".discord.media")
    }

    /// Hosts the updater may connect to: GitHub and the domains it serves release downloads from.
    public static func isUpdateHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return ["github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com"].contains(host)
    }

    // The system anchor array is immutable; the lock protects its one-time publication.
    private struct AnchorArray: @unchecked Sendable {
        let value: CFArray
    }

    private static let anchorLock = OSAllocatedUnfairLock<AnchorArray?>(initialState: nil)

    /// Apple's built-in roots, read once.
    private static func setSystemAnchors(on trust: SecTrust) -> Bool {
        anchorLock.withLock { stored in
            if let stored {
                SecTrustSetAnchorCertificates(trust, stored.value)
                return true
            }
            var anchors: CFArray?
            guard SecTrustCopyAnchorCertificates(&anchors) == errSecSuccess, let anchors else { return false }
            stored = AnchorArray(value: anchors)
            SecTrustSetAnchorCertificates(trust, anchors)
            return true
        }
    }

    public func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if evaluate(challenge), let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        urlSession(session, didReceive: challenge, completionHandler: completionHandler)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let allowed = followsRedirects && request.url?.scheme == "https" && hostPolicy(request.url?.host)
        completionHandler(allowed ? request : nil)
    }

    private func evaluate(_ challenge: URLAuthenticationChallenge) -> Bool {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              hostPolicy(space.host),
              let trust = space.serverTrust else { return false }
        SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, space.host as CFString))
        guard Self.setSystemAnchors(on: trust) else { return false }
        SecTrustSetAnchorCertificatesOnly(trust, true)
        return SecTrustEvaluateWithError(trust, nil)
    }
}
