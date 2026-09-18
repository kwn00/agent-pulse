import Foundation

/// Google Antigravity — talks to the IDE's local language server over loopback,
/// exactly like the editor extension does. Requires Antigravity to be running.
struct AntigravityProvider: UsageProvider {
    let id = ProviderID.antigravity
    let http: HTTPClient

    private static let service = "/exa.language_server_pb.LanguageServerService/"
    private static let quotaSummaryPath = service + "RetrieveUserQuotaSummary"
    private static let userStatusPath = service + "GetUserStatus"

    func fetch() async throws -> UsageSnapshot {
        let servers = try await AntigravityServer.discover()
        var lastError: Error?

        for server in servers {
            for port in server.ports {
                let endpoint = Endpoint(port: port, csrfToken: server.csrfToken)
                do {
                    return try await snapshot(from: endpoint)
                } catch {
                    lastError = error
                }
            }
        }

        if let failure = lastError as? ProviderFailure { throw failure }
        throw ProviderFailure.notRunning(
            "Antigravity's language server isn't answering.",
            hint: "Restart Antigravity, then refresh."
        )
    }

    private struct Endpoint {
        var port: Int
        var csrfToken: String
    }

    private func snapshot(from endpoint: Endpoint) async throws -> UsageSnapshot {
        // Quota summary carries the named quota buckets; user status carries identity + plan.
        let summaryData = try await post(Self.quotaSummaryPath, body: ["forceRefresh": true], endpoint: endpoint)
        let summary = AntigravityQuotaParser.parseSummary(summaryData)

        let statusData = try? await post(Self.userStatusPath, body: Self.metadataBody, endpoint: endpoint)
        let status = statusData.flatMap(AntigravityQuotaParser.parseUserStatus)

        var metrics = summary?.metrics ?? []
        if metrics.isEmpty, let status {
            metrics = status.modelMetrics
        }

        if metrics.isEmpty, summary == nil, status == nil {
            throw ProviderFailure.parsing("Unexpected language server payload.")
        }

        return UsageSnapshot(
            plan: status?.planName,
            account: status?.email,
            metrics: metrics,
            fetchedAt: Date(),
            note: metrics.isEmpty ? "No metered quotas reported yet" : nil
        )
    }

    private static var metadataBody: [String: Any] {
        [
            "metadata": [
                "ideName": "antigravity",
                "extensionName": "antigravity",
                "ideVersion": "unknown",
                "locale": "en",
            ],
        ]
    }

    private func post(_ path: String, body: [String: Any], endpoint: Endpoint) async throws -> Data {
        let url = URL(string: "https://127.0.0.1:\(endpoint.port)\(path)")!
        var request = URLRequest.json("POST", url, body: try JSONSerialization.data(withJSONObject: body))
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue(endpoint.csrfToken, forHTTPHeaderField: "X-Codeium-Csrf-Token")
        request.timeoutInterval = 4

        let (data, response) = try await http.send(request)
        guard response.statusCode == 200 else {
            throw ProviderFailure.network("Language server returned \(response.statusCode) on port \(endpoint.port).")
        }
        return data
    }
}

// MARK: - Discovery

struct AntigravityServer: Sendable {
    var pid: pid_t
    var csrfToken: String
    var ports: [Int]

    static let appCandidates = [
        "/Applications/Antigravity.app",
        Paths.home.appendingPathComponent("Applications/Antigravity.app").path,
    ]

    /// Every Antigravity language server currently running, with the loopback ports it listens on.
    static func discover() async throws -> [AntigravityServer] {
        let installed = appCandidates.contains { FileManager.default.fileExists(atPath: $0) }

        let entries = await Task.detached(priority: .utility) {
            ProcessScanner.entries { path in
                let lower = path.lowercased()
                let name = URL(fileURLWithPath: lower).lastPathComponent
                return lower.contains("antigravity") || name.hasPrefix("language_server") || isCLIName(name)
            }
        }.value

        let servers = entries.compactMap(server(from:))
        guard !servers.isEmpty else {
            if entries.contains(where: isCLI) {
                // The agy CLI embeds its own language server but never exposes its CSRF token,
                // so a CLI-only session can't be read; say so instead of a generic "not running".
                throw ProviderFailure.notRunning(
                    "Antigravity IDE isn't running. The agy CLI is, but it doesn't share quota data.",
                    hint: "Open the Antigravity app for live numbers.",
                    title: "IDE closed · CLI running"
                )
            }
            if installed {
                throw ProviderFailure.notRunning("Antigravity isn't running.", hint: "Open Antigravity to read model quotas.")
            }
            throw ProviderFailure.notInstalled("Antigravity isn't installed on this Mac.", hint: "Install Antigravity and sign in.")
        }

        let withPorts = servers.filter { !$0.ports.isEmpty }
        guard !withPorts.isEmpty else {
            throw ProviderFailure.notRunning("Antigravity is still starting up.", hint: "Give it a moment and refresh.")
        }
        return withPorts
    }

    static func server(from entry: ProcessScanner.Entry) -> AntigravityServer? {
        guard isLanguageServer(entry), isAntigravity(entry) else { return nil }
        guard let token = entry.flag("--csrf_token"), !token.isEmpty else { return nil }
        var ports = ProcessScanner.listeningTCPPorts(entry.pid)
        if let explicit = entry.flag("--extension_server_port").flatMap(Int.init), !ports.contains(explicit) {
            ports.insert(explicit, at: 0)
        }
        return AntigravityServer(pid: entry.pid, csrfToken: token, ports: ports)
    }

    /// `agy` / `antigravity-cli` processes: present, but not queryable.
    static func isCLI(_ entry: ProcessScanner.Entry) -> Bool {
        let executable = URL(fileURLWithPath: entry.executablePath).lastPathComponent.lowercased()
        let argv0 = entry.arguments.first.map { URL(fileURLWithPath: $0).lastPathComponent.lowercased() } ?? ""
        return isCLIName(executable) || isCLIName(argv0)
    }

    /// The self-updater renames the live binary to `agy.<timestamp>.old`, so match the stem, not the whole name.
    static func isCLIName(_ name: String) -> Bool {
        for stem in ["agy", "antigravity-cli", "antigravity_cli"] where name == stem || name.hasPrefix(stem + ".") {
            return true
        }
        return false
    }

    static func isLanguageServer(_ entry: ProcessScanner.Entry) -> Bool {
        let name = URL(fileURLWithPath: entry.executablePath).lastPathComponent.lowercased()
        return name.hasPrefix("language_server") || name.hasPrefix("language-server")
    }

    static func isAntigravity(_ entry: ProcessScanner.Entry) -> Bool {
        let command = (entry.executablePath + " " + entry.commandLine).lowercased()
        if command.contains("antigravity.app/") || command.contains("/antigravity/") { return true }
        if command.contains("--app_data_dir"), command.contains("antigravity") { return true }
        return false
    }
}

// MARK: - Parsing

enum AntigravityQuotaParser {
    struct Summary: Sendable {
        var description: String?
        var metrics: [UsageMetric]
    }

    struct Status: Sendable {
        var email: String?
        var planName: String?
        var modelMetrics: [UsageMetric]
    }

    /// `RetrieveUserQuotaSummary` → `{ groups: [{ displayName, buckets: [{ bucketId, displayName, remainingFraction, resetTime, disabled }] }] }`.
    /// The envelope key has shifted between builds, so the parser looks for `groups` at any depth ≤ 2.
    static func parseSummary(_ data: Data) -> Summary? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let container = findContainer(with: "groups", in: root),
              let groups = container["groups"] as? [[String: Any]] else {
            return nil
        }

        var metrics: [UsageMetric] = []
        for group in groups {
            let groupName = (group["displayName"] as? String).map(shortGroupName)
            let buckets = group["buckets"] as? [[String: Any]] ?? []
            for bucket in buckets {
                if bucket["disabled"] as? Bool == true { continue }
                let bucketName = shortBucketName(
                    window: bucket["window"] as? String,
                    displayName: bucket["displayName"] as? String ?? bucket["bucketId"] as? String ?? "Quota"
                )
                let label: String = {
                    guard let groupName, !groupName.isEmpty, groupName != bucketName else { return bucketName }
                    return buckets.count > 1 ? "\(groupName) · \(bucketName)" : groupName
                }()
                let remaining = remainingFraction(in: bucket)
                metrics.append(UsageMetric(
                    id: bucket["bucketId"] as? String ?? label,
                    label: label,
                    usedFraction: remaining.map { min(max(1 - $0, 0), 1) },
                    resetsAt: (bucket["resetTime"] as? String).flatMap(parseDate),
                    isUnlimited: remaining == nil,
                    isPrimary: true
                ))
            }
        }
        return Summary(description: container["description"] as? String, metrics: metrics)
    }

    static func parseUserStatus(_ data: Data) -> Status? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = root["userStatus"] as? [String: Any] else {
            return nil
        }

        var planName: String?
        if let tier = status["userTier"] as? [String: Any] {
            planName = nonEmpty(tier["name"] as? String)
        }
        if planName == nil, let planStatus = status["planStatus"] as? [String: Any],
           let info = planStatus["planInfo"] as? [String: Any] {
            for key in ["planDisplayName", "displayName", "productName", "planName", "planShortName"] {
                if let value = nonEmpty(info[key] as? String) { planName = value; break }
            }
        }

        var metrics: [UsageMetric] = []
        var seen = Set<String>()
        if let configData = status["cascadeModelConfigData"] as? [String: Any],
           let configs = configData["clientModelConfigs"] as? [[String: Any]] {
            for config in configs {
                guard let quota = config["quotaInfo"] as? [String: Any] else { continue }
                let label = config["label"] as? String
                    ?? (config["modelOrAlias"] as? [String: Any])?["model"] as? String
                    ?? "Model"
                let remaining = remainingFraction(in: quota)
                let key = "\(remaining ?? -1)|\(quota["resetTime"] as? String ?? "")"
                if seen.contains(key) { continue }
                seen.insert(key)
                metrics.append(UsageMetric(
                    id: label,
                    label: label,
                    usedFraction: remaining.map { min(max(1 - $0, 0), 1) },
                    resetsAt: (quota["resetTime"] as? String).flatMap(parseDate),
                    isUnlimited: remaining == nil,
                    isPrimary: true
                ))
            }
        }

        return Status(
            email: nonEmpty(status["email"] as? String),
            planName: planName.map(cleanPlanName),
            modelMetrics: metrics
        )
    }

    /// Accepts `remainingFraction: 0.8` or the protobuf-oneof shape `remaining: { remainingFraction: 0.8 }`.
    static func remainingFraction(in object: [String: Any]) -> Double? {
        if let value = number(object["remainingFraction"]) { return value }
        if let remaining = object["remaining"] as? [String: Any], let value = number(remaining["remainingFraction"]) {
            return value
        }
        return nil
    }

    private static func number(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private static func findContainer(with key: String, in root: [String: Any]) -> [String: Any]? {
        if root[key] != nil { return root }
        for value in root.values {
            if let nested = value as? [String: Any], nested[key] != nil { return nested }
        }
        return nil
    }

    private static func nonEmpty(_ string: String?) -> String? {
        guard let string, !string.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return string
    }

    /// "Gemini Models" → "Gemini", "Claude and GPT models" → "Claude & GPT".
    static func shortGroupName(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespaces)
        for suffix in [" Models", " models"] where name.hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
        }
        return name.replacingOccurrences(of: " and ", with: " & ")
    }

    /// Prefers the machine-readable `window` ("weekly", "5h"), falling back to trimming the display name:
    /// "Five Hour Limit Remaining" → "5-hour", "Weekly Limit Remaining" → "Weekly".
    static func shortBucketName(window: String?, displayName raw: String) -> String {
        switch window?.lowercased() {
        case "weekly", "week": return "Weekly"
        case "daily", "day", "24h": return "Daily"
        case "monthly", "month": return "Monthly"
        case let some? where some.hasSuffix("h") && Int(some.dropLast()) != nil: return "\(some.dropLast())-hour"
        default: break
        }
        var name = raw.trimmingCharacters(in: .whitespaces)
        var trimmed = true
        while trimmed {
            trimmed = false
            for suffix in [" Remaining", " remaining", " Limit", " limit", " Quota", " quota"] where name.hasSuffix(suffix) {
                name = String(name.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
                trimmed = true
            }
        }
        let lower = name.lowercased()
        if ["five hour", "five-hour", "5 hour", "5-hour", "5h"].contains(lower) { return "5-hour" }
        if ["daily", "day", "24 hour", "24-hour"].contains(lower) { return "Daily" }
        if lower == "week" { return "Weekly" }
        return name.isEmpty ? raw : name
    }

    static func cleanPlanName(_ raw: String) -> String {
        raw.replacingOccurrences(of: "Google ", with: "")
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    static func parseDate(_ string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) ?? ISO8601DateFormatter().date(from: string) { return date }
        if let seconds = Double(string) { return Date(timeIntervalSince1970: seconds) }
        return nil
    }
}
