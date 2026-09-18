import Foundation

/// Thin URLSession wrapper. Trusts self-signed certificates for loopback hosts only,
/// which is what Antigravity's local language server presents.
final class HTTPClient: Sendable {
    static let shared = HTTPClient()

    private let session: URLSession

    init(timeout: TimeInterval = 15) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 2
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration, delegate: LoopbackTrustDelegate(), delegateQueue: nil)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderFailure.network("Non-HTTP response.")
        }
        return (data, http)
    }

    func json<T: Decodable>(_ type: T.Type, from data: Data, snakeCase: Bool = true) throws -> T {
        let decoder = JSONDecoder()
        if snakeCase { decoder.keyDecodingStrategy = .convertFromSnakeCase }
        return try decoder.decode(type, from: data)
    }
}

extension URLRequest {
    static func json(_ method: String, _ url: URL, body: Data? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }
}

private final class LoopbackTrustDelegate: NSObject, URLSessionDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let space = challenge.protectionSpace
        let isLoopback = ["127.0.0.1", "localhost", "::1"].contains(space.host)
        if space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           isLoopback,
           let trust = space.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
