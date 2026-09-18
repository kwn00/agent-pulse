import Foundation

/// GitHub Copilot — reuses the OAuth token the Copilot CLI / IDE plugins keep in `~/.config/github-copilot`.
struct CopilotProvider: UsageProvider {
    let id = ProviderID.copilot
    let http: HTTPClient

    private static let userURL = URL(string: "https://api.github.com/copilot_internal/user")!

    func fetch() async throws -> UsageSnapshot {
        let token = try await CopilotToken.resolve()

        var request = URLRequest.json("GET", Self.userURL)
        // GitHub expects the classic `token` scheme here plus Copilot-client identification headers.
        request.setValue("token \(token.value)", forHTTPHeaderField: "Authorization")
        request.setValue("vscode/1.104.0", forHTTPHeaderField: "Editor-Version")
        request.setValue("copilot-chat/0.31.0", forHTTPHeaderField: "Editor-Plugin-Version")
        request.setValue("GitHubCopilotChat/0.31.0", forHTTPHeaderField: "User-Agent")
        request.setValue("2025-04-01", forHTTPHeaderField: "X-GitHub-Api-Version")

        let (data, response) = try await http.send(request)
        switch response.statusCode {
        case 200:
            break
        case 401, 403:
            if token.source == .githubCLI {
                throw ProviderFailure.notSignedIn(
                    "Copilot isn't signed in on this Mac.",
                    hint: "The `gh` token can't read Copilot usage. Run `copilot` once or sign in from your editor."
                )
            }
            throw ProviderFailure.unauthorized("GitHub rejected the Copilot token.", hint: "Sign in again with `copilot` or your editor's Copilot plugin.")
        case 404:
            throw ProviderFailure.notSignedIn("No Copilot seat on this account.", hint: "Check your plan at github.com/settings/copilot.")
        default:
            throw ProviderFailure.network("GitHub returned \(response.statusCode).")
        }

        let user = try http.json(CopilotUserResponse.self, from: data)
        return Self.snapshot(from: user, login: token.login)
    }

    static func snapshot(from user: CopilotUserResponse, login: String?, now: Date = Date()) -> UsageSnapshot {
        var metrics: [UsageMetric] = []
        let resetsAt = (user.quotaResetDateUtc ?? user.quotaResetDate).flatMap(parseResetDate)

        let ordered: [(key: String, label: String)] = [
            ("premium_interactions", "Premium requests"),
            ("chat", "Chat"),
            ("completions", "Completions"),
        ]

        for (key, label) in ordered {
            guard let quota = user.quotaSnapshots?[key] else { continue }
            if quota.unlimited == true {
                metrics.append(UsageMetric(id: key, label: label, isUnlimited: true))
                continue
            }
            // entitlement 0 / remaining 0 / percent 0 is GitHub's placeholder for "not metered".
            if quota.isPlaceholder { continue }

            let entitlement = quota.entitlement ?? 0
            let remaining = max(quota.remaining ?? 0, 0)
            let used = quota.creditsUsed ?? max(entitlement - remaining, 0)
            let fraction: Double? = {
                if let percentRemaining = quota.percentRemaining { return min(max(1 - percentRemaining / 100, 0), 1) }
                guard entitlement > 0 else { return nil }
                return min(used / entitlement, 1)
            }()
            var detail = entitlement > 0 ? "\(used.grouped) / \(entitlement.grouped)" : "\(used.grouped) used"
            if let overage = quota.overageCount, overage > 0 {
                detail += " · +\(overage.grouped) over"
            }
            metrics.append(UsageMetric(
                id: key,
                label: label,
                usedFraction: fraction,
                detail: detail,
                resetsAt: resetsAt,
                isPrimary: key == "premium_interactions"
            ))
        }

        var note: String?
        if let premium = user.quotaSnapshots?["premium_interactions"], premium.unlimited != true, !premium.isPlaceholder {
            note = premium.overagePermitted == true ? "Overage billing enabled" : "Hard stop at quota"
        }

        return UsageSnapshot(
            plan: planName(user.copilotPlan),
            account: user.login ?? login,
            metrics: metrics,
            fetchedAt: now,
            note: note
        )
    }

    static func planName(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        switch raw.lowercased() {
        case "free": return "Free"
        case "individual": return "Pro"
        case "individual_pro", "pro_plus": return "Pro+"
        case "business": return "Business"
        case "enterprise": return "Enterprise"
        case "unknown": return nil
        default: return raw.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// `quota_reset_date` is `YYYY-MM-DD`; `quota_reset_date_utc` is full ISO-8601.
    static func parseResetDate(_ string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) ?? ISO8601DateFormatter().date(from: string) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: string)
    }
}

struct CopilotToken: Sendable {
    enum Source: Sendable { case configFile, githubCLI }

    var value: String
    var login: String?
    var source: Source = .configFile

    static var configDirectory: URL {
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: xdg).appendingPathComponent("github-copilot")
        }
        return Paths.home.appendingPathComponent(".config/github-copilot")
    }

    static func resolve() async throws -> CopilotToken {
        if let token = fromConfigFiles() { return token }
        if let token = try? await fromGitHubCLI() { return token }
        if FileManager.default.fileExists(atPath: configDirectory.path) {
            throw ProviderFailure.notSignedIn("Copilot isn't signed in.", hint: "Run `copilot` or sign in from your editor.")
        }
        throw ProviderFailure.notInstalled("No Copilot credentials on this Mac.", hint: "Install the Copilot CLI or an IDE plugin and sign in.")
    }

    /// `apps.json` / `hosts.json`: `{ "github.com:Iv1.xxx": { "user": "...", "oauth_token": "gho_..." } }`
    static func fromConfigFiles() -> CopilotToken? {
        for name in ["apps.json", "hosts.json"] {
            let url = configDirectory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let token = parse(object) { return token }
        }
        return nil
    }

    static func parse(_ object: [String: Any]) -> CopilotToken? {
        for key in object.keys.sorted() where key.hasPrefix("github.com") {
            guard let entry = object[key] as? [String: Any],
                  let token = entry["oauth_token"] as? String, !token.isEmpty else { continue }
            return CopilotToken(value: token, login: entry["user"] as? String)
        }
        return nil
    }

    static func fromGitHubCLI() async throws -> CopilotToken? {
        for candidate in ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"] {
            guard FileManager.default.isExecutableFile(atPath: candidate) else { continue }
            let output = try await Shell.run(candidate, ["auth", "token"])
            let token = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard output.status == 0, !token.isEmpty else { return nil }
            return CopilotToken(value: token, login: nil, source: .githubCLI)
        }
        return nil
    }
}

struct CopilotUserResponse: Decodable, Sendable {
    var login: String?
    var copilotPlan: String?
    var quotaResetDate: String?
    var quotaResetDateUtc: String?
    var quotaSnapshots: [String: QuotaSnapshot]?

    struct QuotaSnapshot: Decodable, Sendable {
        var entitlement: Double?
        var remaining: Double?
        var percentRemaining: Double?
        var unlimited: Bool?
        var overageCount: Double?
        var overagePermitted: Bool?
        var creditsUsed: Double?
        var quotaId: String?

        var isPlaceholder: Bool {
            (entitlement ?? 0) == 0 && (remaining ?? 0) == 0 && (percentRemaining ?? 0) == 0 && (creditsUsed ?? 0) == 0
        }
    }
}
