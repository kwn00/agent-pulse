import Foundation

/// OpenAI Codex CLI — reuses the OAuth session in `~/.codex/auth.json`.
///
/// Codex owns that file and rotates its own tokens, so this provider never redeems the refresh
/// token; an expired session is surfaced as "run `codex` once" instead.
struct CodexProvider: UsageProvider {
    let id = ProviderID.codex
    let http: HTTPClient

    private static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    func fetch() async throws -> UsageSnapshot {
        let credentials = try CodexCredentials.load()
        if let expiry = credentials.accessTokenExpiry, expiry.timeIntervalSinceNow < 60 {
            throw ProviderFailure.unauthorized("Codex session expired.", hint: "Run `codex` once so it refreshes its login.")
        }

        var request = URLRequest.json("GET", Self.usageURL)
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        if let accountID = credentials.accountID {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        request.setValue("AgentPulse", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await http.send(request)
        switch response.statusCode {
        case 200:
            break
        case 401, 403:
            throw ProviderFailure.unauthorized("Codex session was rejected.", hint: "Run `codex` once so it refreshes its login.")
        case 429:
            throw ProviderFailure.network("ChatGPT is rate limiting usage lookups.")
        default:
            throw ProviderFailure.network("ChatGPT usage API returned \(response.statusCode).")
        }

        let usage = try http.json(CodexUsageResponse.self, from: data)
        return Self.snapshot(from: usage, credentials: credentials)
    }

    static func snapshot(from usage: CodexUsageResponse, credentials: CodexCredentials, now: Date = Date()) -> UsageSnapshot {
        var metrics: [UsageMetric] = []

        if let primary = usage.rateLimit?.primaryWindow {
            metrics.append(metric(id: "primary", window: primary, prefix: nil, isPrimary: true, now: now))
        }
        if let secondary = usage.rateLimit?.secondaryWindow {
            metrics.append(metric(id: "secondary", window: secondary, prefix: nil, isPrimary: true, now: now))
        }

        // Model-specific pools (e.g. "gpt-reserve") ride along as secondary metrics.
        for extra in usage.additionalRateLimits ?? [] {
            let name = humanize(extra.limitName ?? extra.normalModelSlug ?? "Additional")
            if let window = extra.rateLimit?.primaryWindow {
                metrics.append(metric(id: "extra-\(name)-p", window: window, prefix: name, isPrimary: false, now: now))
            }
            if let window = extra.rateLimit?.secondaryWindow {
                metrics.append(metric(id: "extra-\(name)-s", window: window, prefix: name, isPrimary: false, now: now))
            }
        }

        var note: String?
        if usage.rateLimit?.limitReached == true {
            note = "Rate limit reached"
        } else if let credits = usage.credits, credits.hasCredits == true {
            note = credits.unlimited == true ? "Unlimited credits" : credits.balance.map { "Credits: \($0.grouped) left" }
        }

        return UsageSnapshot(
            plan: planName(usage.planType ?? credentials.planType),
            account: usage.email ?? credentials.email,
            metrics: metrics,
            fetchedAt: now,
            note: note
        )
    }

    private static func metric(id: String, window: CodexUsageResponse.Window, prefix: String?, isPrimary: Bool, now: Date) -> UsageMetric {
        let usedPercent = window.usedPercent
        var resetsAt: Date?
        if let resetAt = window.resetAt {
            resetsAt = Date(timeIntervalSince1970: resetAt)
        } else if let after = window.resetAfterSeconds {
            resetsAt = now.addingTimeInterval(after)
        }
        let label = windowLabel(seconds: window.limitWindowSeconds)
        return UsageMetric(
            id: id,
            label: prefix.map { "\($0) · \(label)" } ?? label,
            usedFraction: min(max(usedPercent / 100, 0), 1),
            detail: usedPercent > 100 ? "Over quota" : nil,
            resetsAt: resetsAt,
            isPrimary: isPrimary
        )
    }

    static func windowLabel(seconds: Double?) -> String {
        guard let seconds, seconds > 0 else { return "Rate limit" }
        let hours = seconds / 3600
        if hours < 1 { return "\(Int((seconds / 60).rounded()))-minute limit" }
        if hours < 24 { return "\(Int(hours.rounded()))-hour limit" }
        let days = hours / 24
        if abs(days - 7) < 0.5 { return "Weekly limit" }
        if abs(days - 30) < 1.5 { return "Monthly limit" }
        return "\(Int(days.rounded()))-day limit"
    }

    static func humanize(_ slug: String) -> String {
        slug.split(whereSeparator: { $0 == "-" || $0 == "_" })
            .map { part -> String in
                let text = String(part)
                return text.lowercased() == "gpt" ? "GPT" : text.capitalized
            }
            .joined(separator: " ")
    }

    static func planName(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        switch raw.lowercased() {
        case "plus": return "Plus"
        case "pro": return "Pro"
        case "go": return "Go"
        case "team": return "Team"
        case "business": return "Business"
        case "enterprise": return "Enterprise"
        case "edu", "education": return "Edu"
        case "free": return "Free"
        default: return raw.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

struct CodexCredentials: Sendable {
    var accessToken: String
    var idToken: String?
    var accountID: String?

    var accessTokenExpiry: Date? { JWT.expiry(accessToken) }

    var email: String? {
        guard let idToken, let claims = JWT.claims(idToken) else { return nil }
        if let email = claims["email"] as? String { return email }
        return (claims["https://api.openai.com/profile"] as? [String: Any])?["email"] as? String
    }

    var planType: String? {
        guard let idToken, let claims = JWT.claims(idToken) else { return nil }
        let auth = claims["https://api.openai.com/auth"] as? [String: Any]
        return (auth?["chatgpt_plan_type"] as? String) ?? (claims["chatgpt_plan_type"] as? String)
    }

    static var fileURL: URL {
        if let custom = ProcessInfo.processInfo.environment["CODEX_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: custom).appendingPathComponent("auth.json")
        }
        let primary = Paths.home.appendingPathComponent(".codex/auth.json")
        if FileManager.default.fileExists(atPath: primary.path) { return primary }
        let legacy = Paths.home.appendingPathComponent(".config/codex/auth.json")
        return FileManager.default.fileExists(atPath: legacy.path) ? legacy : primary
    }

    static func load(from url: URL = fileURL) throws -> CodexCredentials {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ProviderFailure.notInstalled("Codex CLI isn't set up on this Mac.", hint: "Install Codex and run `codex login`.")
        }
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderFailure.parsing("auth.json is not valid JSON.")
        }
        return try parse(object)
    }

    static func parse(_ object: [String: Any]) throws -> CodexCredentials {
        let tokens = object["tokens"] as? [String: Any]
        let accessToken = string("access_token", "accessToken", in: tokens)
        guard let accessToken, !accessToken.isEmpty else {
            if let apiKey = object["OPENAI_API_KEY"] as? String, !apiKey.isEmpty {
                throw ProviderFailure.notSignedIn(
                    "Codex is using an API key.",
                    hint: "Usage windows only exist for ChatGPT sign-in. Run `codex login`."
                )
            }
            throw ProviderFailure.notSignedIn("Codex isn't signed in.", hint: "Run `codex login` in a terminal.")
        }

        let idToken = string("id_token", "idToken", in: tokens)
        var accountID = string("account_id", "accountId", in: tokens)
        if accountID == nil {
            for token in [idToken, accessToken].compactMap({ $0 }) {
                guard let claims = JWT.claims(token) else { continue }
                if let direct = claims["chatgpt_account_id"] as? String, !direct.isEmpty { accountID = direct; break }
                if let auth = claims["https://api.openai.com/auth"] as? [String: Any],
                   let nested = auth["chatgpt_account_id"] as? String, !nested.isEmpty { accountID = nested; break }
            }
        }
        return CodexCredentials(accessToken: accessToken, idToken: idToken, accountID: accountID)
    }

    private static func string(_ snake: String, _ camel: String, in object: [String: Any]?) -> String? {
        guard let object else { return nil }
        return (object[snake] as? String) ?? (object[camel] as? String)
    }
}

struct CodexUsageResponse: Decodable, Sendable {
    var email: String?
    var planType: String?
    var rateLimit: RateLimit?
    var additionalRateLimits: [AdditionalRateLimit]?
    var credits: Credits?

    struct RateLimit: Decodable, Sendable {
        var allowed: Bool?
        var limitReached: Bool?
        var primaryWindow: Window?
        var secondaryWindow: Window?
    }

    struct Window: Decodable, Sendable {
        var usedPercent: Double
        var limitWindowSeconds: Double?
        var resetAfterSeconds: Double?
        /// Absolute UNIX epoch seconds.
        var resetAt: Double?
    }

    struct AdditionalRateLimit: Decodable, Sendable {
        var limitName: String?
        var normalModelSlug: String?
        var rateLimit: RateLimit?
    }

    struct Credits: Decodable, Sendable {
        var hasCredits: Bool?
        var unlimited: Bool?
        var balance: Double?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            hasCredits = try container.decodeIfPresent(Bool.self, forKey: .hasCredits)
            unlimited = try container.decodeIfPresent(Bool.self, forKey: .unlimited)
            if let number = try? container.decodeIfPresent(Double.self, forKey: .balance) {
                balance = number
            } else if let string = try? container.decodeIfPresent(String.self, forKey: .balance) {
                balance = Double(string)
            }
        }

        private enum CodingKeys: String, CodingKey { case hasCredits, unlimited, balance }
    }
}
