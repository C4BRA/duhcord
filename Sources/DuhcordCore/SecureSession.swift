import Foundation
import Security

/// The only URLSession Duhcord uses to talk to Discord. It exists to make sure the token can't leave for
/// anywhere but Discord:
///
/// - Connections are only allowed to Discord's own hosts. Anything else is cancelled before TLS completes.
/// - Certificates must chain to one of Apple's built-in root certificates. Roots added by the user or an
///   administrator (the way corporate proxies and interception tools read TLS traffic) are not trusted.
/// - Redirects are refused, because URLSession would otherwise carry the Authorization header to the new host.
public final class SecureSession: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    public static let shared = SecureSession()

    public private(set) lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        // Nothing about our traffic is written to disk: no cookies, no cache.
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.tlsMinimumSupportedProtocolVersion = .TLSv12
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    /// Hosts Duhcord may connect to.
    public static func isAllowed(host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "discord.com" || host == "discord.gg" || host.hasSuffix(".discord.gg")
    }

    /// Apple's built-in roots, read once.
    private static let systemAnchors: CFArray? = {
        var anchors: CFArray?
        guard SecTrustCopyAnchorCertificates(&anchors) == errSecSuccess else { return nil }
        return anchors
    }()

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
        completionHandler(nil)
    }

    private func evaluate(_ challenge: URLAuthenticationChallenge) -> Bool {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              Self.isAllowed(host: space.host),
              let trust = space.serverTrust,
              let anchors = Self.systemAnchors else { return false }
        SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, space.host as CFString))
        SecTrustSetAnchorCertificates(trust, anchors)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        return SecTrustEvaluateWithError(trust, nil)
    }
}
