import Foundation

/// Cursor — reuses the session token the Cursor IDE stores in its `state.vscdb`.
struct CursorProvider: UsageProvider {
    let id = ProviderID.cursor
    let http: HTTPClient

    private static let summaryURL = URL(string: "https://cursor.com/api/usage-summary")!

    func fetch() async throws -> UsageSnapshot {
        let session = try CursorSession.load()
        if let expiry = JWT.expiry(session.accessToken), expiry.timeIntervalSinceNow < 60 {
            throw ProviderFailure.unauthorized("Cursor session expired.", hint: "Open Cursor so it renews its session.")
        }

        var request = URLRequest.json("GET", Self.summaryURL)
        request.setValue(session.cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
        request.setValue("https://cursor.com/dashboard", forHTTPHeaderField: "Referer")

        let (data, response) = try await http.send(request)
        switch response.statusCode {
        case 200:
            break
        case 401, 403:
            throw ProviderFailure.unauthorized("Cursor rejected the local session.", hint: "Open Cursor and sign in again.")
        default:
            throw ProviderFailure.network("Cursor returned \(response.statusCode).")
        }

        let summary = try http.json(CursorUsageSummary.self, from: data, snakeCase: false)
        return Self.snapshot(summary: summary, session: session)
    }

    static func snapshot(summary: CursorUsageSummary, session: CursorSession, now: Date = Date()) -> UsageSnapshot {
        var metrics: [UsageMetric] = []
        let cycleEnd = summary.billingCycleEnd.flatMap(parseDate)
        let unlimited = summary.isUnlimited == true

        if let plan = summary.individualUsage?.plan, plan.enabled != false {
            let includedCents = plan.limit ?? plan.breakdown?.included
            let bonusCents = plan.breakdown?.bonus ?? 0
            let detail: String? = {
                guard let includedCents else { return nil }
                let included = Double(includedCents) / 100
                if bonusCents > 0 {
                    return "\(included.usd) + \((Double(bonusCents) / 100).usd) bonus"
                }
                let used = Double(plan.used ?? 0) / 100
                return "\(used.usd) / \(included.usd)"
            }()
            metrics.append(UsageMetric(
                id: "plan",
                label: "Included usage",
                usedFraction: unlimited ? nil : planFraction(plan),
                detail: detail,
                resetsAt: cycleEnd,
                isUnlimited: unlimited,
                isPrimary: true
            ))

            // Sub-breakdowns: Auto (included models) vs. named-model API usage.
            if let auto = plan.autoPercentUsed, let api = plan.apiPercentUsed, !unlimited {
                metrics.append(UsageMetric(id: "auto", label: "Auto models", usedFraction: clamp(auto / 100), resetsAt: cycleEnd))
                metrics.append(UsageMetric(id: "api", label: "Named models", usedFraction: clamp(api / 100), resetsAt: cycleEnd))
            }
        }

        if let onDemand = summary.individualUsage?.onDemand, onDemand.enabled == true {
            let used = Double(onDemand.used ?? 0) / 100
            let limit = onDemand.limit.map { Double($0) / 100 }
            metrics.append(UsageMetric(
                id: "on-demand",
                label: "On-demand",
                usedFraction: limit.flatMap { $0 > 0 ? clamp(used / $0) : nil },
                detail: limit.map { "\(used.usd) / \($0.usd)" } ?? used.usd,
                resetsAt: cycleEnd
            ))
        }

        if let pooled = summary.teamUsage?.pooled ?? summary.teamUsage?.plan, pooled.enabled != false, pooled.limit != nil {
            let used = Double(pooled.used ?? 0) / 100
            let limit = Double(pooled.limit ?? 0) / 100
            metrics.append(UsageMetric(
                id: "team",
                label: "Team pool",
                usedFraction: limit > 0 ? clamp(used / limit) : nil,
                detail: "\(used.usd) / \(limit.usd)",
                resetsAt: cycleEnd
            ))
        }

        return UsageSnapshot(
            plan: planName(summary.membershipType ?? session.membershipType),
            account: session.email,
            metrics: metrics,
            fetchedAt: now,
            note: summary.autoModelSelectedDisplayMessage
        )
    }

    /// Mirrors Cursor's own dashboard: percent fields first, cents ratio as the fallback.
    static func planFraction(_ plan: CursorUsageSummary.Bucket) -> Double? {
        if let total = plan.totalPercentUsed { return clamp(total / 100) }
        if let auto = plan.autoPercentUsed, let api = plan.apiPercentUsed { return clamp((auto + api) / 200) }
        if let single = plan.autoPercentUsed ?? plan.apiPercentUsed { return clamp(single / 100) }
        if let used = plan.used, let limit = plan.limit, limit > 0 { return clamp(Double(used) / Double(limit)) }
        return nil
    }

    private static func clamp(_ value: Double) -> Double { min(max(value, 0), 1) }

    static func planName(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        switch raw.lowercased() {
        case "free": return "Hobby"
        case "free_trial": return "Trial"
        case "pro": return "Pro"
        case "pro_plus": return "Pro+"
        case "ultra": return "Ultra"
        case "enterprise": return "Enterprise"
        case "team", "teams", "business": return "Teams"
        default: return raw.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    static func parseDate(_ string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}

struct CursorSession: Sendable {
    var accessToken: String
    var userID: String
    var email: String?
    var membershipType: String?

    /// Cursor's dashboard cookie: `<userId>::<jwt>`, URL-encoded.
    var cookieHeader: String {
        "WorkosCursorSessionToken=\(userID)%3A%3A\(accessToken)"
    }

    static var databaseURL: URL {
        Paths.home.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    }

    static func load(from url: URL = databaseURL) throws -> CursorSession {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ProviderFailure.notInstalled("Cursor isn't installed on this Mac.", hint: "Install Cursor and sign in once.")
        }
        let values: [String: String]
        do {
            values = try SQLiteReader.values(
                forKeys: ["cursorAuth/accessToken", "cursorAuth/cachedEmail", "cursorAuth/stripeMembershipType"],
                dbPath: url
            )
        } catch {
            throw ProviderFailure.parsing("Couldn't read Cursor's local state.")
        }
        guard let token = values["cursorAuth/accessToken"]?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            throw ProviderFailure.notSignedIn("Cursor isn't signed in.", hint: "Open Cursor and sign in.")
        }
        guard let userID = userID(fromToken: token) else {
            throw ProviderFailure.parsing("Cursor token has no user id.")
        }
        return CursorSession(
            accessToken: token,
            userID: userID,
            email: values["cursorAuth/cachedEmail"],
            membershipType: values["cursorAuth/stripeMembershipType"]
        )
    }

    /// `sub` looks like `auth0|user_01ABC` or `github|123`; Cursor wants the part after the last `|`.
    static func userID(fromToken token: String) -> String? {
        guard let sub = JWT.string("sub", in: token) else { return nil }
        let id = sub.split(separator: "|", omittingEmptySubsequences: true).last.map(String.init) ?? sub
        return id.isEmpty ? nil : id
    }
}

struct CursorUsageSummary: Decodable, Sendable {
    var billingCycleStart: String?
    var billingCycleEnd: String?
    var membershipType: String?
    var limitType: String?
    var isUnlimited: Bool?
    var autoModelSelectedDisplayMessage: String?
    var individualUsage: Usage?
    var teamUsage: TeamUsage?

    struct Usage: Decodable, Sendable {
        var plan: Bucket?
        var onDemand: Bucket?
        var overall: Bucket?
    }

    struct TeamUsage: Decodable, Sendable {
        var plan: Bucket?
        var pooled: Bucket?
    }

    /// Money is integer cents; the `*PercentUsed` fields are already percentages.
    struct Bucket: Decodable, Sendable {
        var enabled: Bool?
        var used: Int?
        var limit: Int?
        var remaining: Int?
        var breakdown: Breakdown?
        var autoPercentUsed: Double?
        var apiPercentUsed: Double?
        var totalPercentUsed: Double?
    }

    struct Breakdown: Decodable, Sendable {
        var included: Int?
        var bonus: Int?
        var total: Int?
    }
}
