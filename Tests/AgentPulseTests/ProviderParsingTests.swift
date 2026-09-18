import Foundation
import XCTest
@testable import AgentPulse

final class ProviderParsingTests: XCTestCase {
    private let http = HTTPClient()
    private let now = Date(timeIntervalSince1970: 1_789_700_000)

    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    // MARK: Codex

    func testCodexSnapshotBuildsPrimaryWindowsAndExtras() throws {
        let response = try http.json(CodexUsageResponse.self, from: fixture("codex_usage"))
        let credentials = CodexCredentials(accessToken: "x", idToken: nil, accountID: "acct")
        let snapshot = CodexProvider.snapshot(from: response, credentials: credentials, now: now)

        XCTAssertEqual(snapshot.plan, "Plus")
        XCTAssertEqual(snapshot.account, "dev@example.com")
        XCTAssertEqual(snapshot.metrics.map(\.label), ["5-hour limit", "Weekly limit", "GPT Reserve · Weekly limit"])
        XCTAssertEqual(snapshot.metrics[1].usedPercent, 14)
        XCTAssertEqual(snapshot.metrics[1].resetsAt, Date(timeIntervalSince1970: 1_789_970_642))
        XCTAssertEqual(snapshot.metrics.filter(\.isPrimary).count, 2)
        XCTAssertEqual(snapshot.headlineFraction, 0.14)
        XCTAssertNil(snapshot.note)
    }

    func testCodexCredentialsFallBackToJWTAccountID() throws {
        let idToken = makeJWT(["https://api.openai.com/auth": ["chatgpt_account_id": "acct-jwt", "chatgpt_plan_type": "pro"], "email": "me@example.com"])
        let credentials = try CodexCredentials.parse([
            "tokens": ["access_token": "abc", "refresh_token": "r", "id_token": idToken],
        ])
        XCTAssertEqual(credentials.accountID, "acct-jwt")
        XCTAssertEqual(credentials.planType, "pro")
        XCTAssertEqual(credentials.email, "me@example.com")
    }

    func testCodexCredentialsRejectAPIKeyOnlyAuth() {
        XCTAssertThrowsError(try CodexCredentials.parse(["OPENAI_API_KEY": "sk-test"])) { error in
            XCTAssertEqual((error as? ProviderFailure)?.kind, .notSignedIn)
        }
    }

    func testCodexWindowLabels() {
        XCTAssertEqual(CodexProvider.windowLabel(seconds: 18000), "5-hour limit")
        XCTAssertEqual(CodexProvider.windowLabel(seconds: 604_800), "Weekly limit")
        XCTAssertEqual(CodexProvider.windowLabel(seconds: 1800), "30-minute limit")
        XCTAssertEqual(CodexProvider.windowLabel(seconds: nil), "Rate limit")
    }

    // MARK: Copilot

    func testCopilotSnapshotSeparatesMeteredAndUnlimitedQuotas() throws {
        let response = try http.json(CopilotUserResponse.self, from: fixture("copilot_user"))
        let snapshot = CopilotProvider.snapshot(from: response, login: nil, now: now)

        XCTAssertEqual(snapshot.plan, "Enterprise")
        XCTAssertEqual(snapshot.account, "octocat")

        let premium = try XCTUnwrap(snapshot.metrics.first { $0.id == "premium_interactions" })
        XCTAssertTrue(premium.isPrimary)
        XCTAssertEqual(premium.usedPercent, 45)
        XCTAssertEqual(premium.detail, "22,532 / 50,000")
        XCTAssertEqual(premium.resetsAt, CopilotProvider.parseResetDate("2026-10-01T00:00:00.000Z"))

        XCTAssertEqual(snapshot.metrics.filter(\.isUnlimited).map(\.label), ["Chat", "Completions"])
        XCTAssertEqual(snapshot.note, "Overage billing enabled")
    }

    func testCopilotPlaceholderQuotaIsSkipped() {
        let placeholder = CopilotUserResponse.QuotaSnapshot(entitlement: 0, remaining: 0, percentRemaining: 0, unlimited: false)
        XCTAssertTrue(placeholder.isPlaceholder)
        let response = CopilotUserResponse(login: nil, copilotPlan: "free", quotaSnapshots: ["premium_interactions": placeholder])
        XCTAssertTrue(CopilotProvider.snapshot(from: response, login: "x", now: now).metrics.isEmpty)
    }

    func testCopilotTokenParsing() {
        let token = CopilotToken.parse([
            "github.com:Iv1.abc": ["user": "octocat", "oauth_token": "gho_secret", "githubAppId": "Iv1.abc"],
        ])
        XCTAssertEqual(token?.value, "gho_secret")
        XCTAssertEqual(token?.login, "octocat")
        XCTAssertNil(CopilotToken.parse(["github.com:Iv1.abc": ["user": "octocat"]]))
    }

    // MARK: Cursor

    func testCursorSnapshotPrefersTotalPercentAndShowsBonus() throws {
        let summary = try http.json(CursorUsageSummary.self, from: fixture("cursor_usage_summary"), snakeCase: false)
        let session = CursorSession(accessToken: "t", userID: "user_1", email: "dev@example.com", membershipType: "pro")
        let snapshot = CursorProvider.snapshot(summary: summary, session: session, now: now)

        XCTAssertEqual(snapshot.plan, "Pro")
        let plan = try XCTUnwrap(snapshot.metrics.first)
        XCTAssertEqual(plan.label, "Included usage")
        XCTAssertEqual(plan.usedPercent, 24)
        XCTAssertEqual(plan.detail, "$20.00 + $93.37 bonus")
        XCTAssertEqual(plan.resetsAt, CursorProvider.parseDate("2026-10-09T01:27:21.000Z"))
        XCTAssertEqual(snapshot.metrics.map(\.label), ["Included usage", "Auto models", "Named models"])
        XCTAssertEqual(snapshot.note, "You've used 24% of your included total usage")
    }

    func testCursorPlanFractionFallsBackToCents() {
        let bucket = CursorUsageSummary.Bucket(enabled: true, used: 1250, limit: 2000)
        XCTAssertEqual(CursorProvider.planFraction(bucket)!, 0.625, accuracy: 0.0001)
    }

    func testCursorUserIDFromSubjectClaim() {
        XCTAssertEqual(CursorSession.userID(fromToken: makeJWT(["sub": "auth0|user_01ABC"])), "user_01ABC")
        XCTAssertEqual(CursorSession.userID(fromToken: makeJWT(["sub": "github|1234"])), "1234")
        XCTAssertNil(CursorSession.userID(fromToken: "not-a-jwt"))
        XCTAssertEqual(
            CursorSession(accessToken: "tok", userID: "u1").cookieHeader,
            "WorkosCursorSessionToken=u1%3A%3Atok"
        )
    }

    // MARK: Antigravity

    func testAntigravityQuotaSummaryParsing() throws {
        let summary = try XCTUnwrap(AntigravityQuotaParser.parseSummary(fixture("antigravity_quota_summary")))
        XCTAssertEqual(summary.metrics.map(\.label), ["Gemini · Weekly", "Gemini · 5-hour", "Claude & GPT · Weekly"])
        XCTAssertEqual(summary.metrics[0].usedPercent, 1)
        XCTAssertEqual(summary.metrics[2].usedPercent, 60)
        XCTAssertEqual(summary.metrics[0].resetsAt, AntigravityQuotaParser.parseDate("2026-09-24T01:13:45Z"))
        XCTAssertTrue(summary.metrics.allSatisfy(\.isPrimary))
    }

    func testAntigravityUserStatusParsing() throws {
        let status = try XCTUnwrap(AntigravityQuotaParser.parseUserStatus(fixture("antigravity_user_status")))
        XCTAssertEqual(status.email, "dev@example.com")
        XCTAssertEqual(status.planName, "AI Pro")
        // Two Gemini aliases share one pool and collapse into a single row.
        XCTAssertEqual(status.modelMetrics.map(\.label), ["Gemini 3 Pro", "Claude Sonnet"])
        XCTAssertEqual(status.modelMetrics[1].usedPercent, 80)
        XCTAssertEqual(status.modelMetrics[1].resetsAt, Date(timeIntervalSince1970: 1_789_970_642))
    }

    func testAntigravityBucketNames() {
        XCTAssertEqual(AntigravityQuotaParser.shortBucketName(window: "5h", displayName: "Five Hour Limit Remaining"), "5-hour")
        XCTAssertEqual(AntigravityQuotaParser.shortBucketName(window: nil, displayName: "Five Hour Limit Remaining"), "5-hour")
        XCTAssertEqual(AntigravityQuotaParser.shortBucketName(window: nil, displayName: "Weekly Limit"), "Weekly")
        XCTAssertEqual(AntigravityQuotaParser.shortGroupName("Claude and GPT models"), "Claude & GPT")
        XCTAssertEqual(AntigravityQuotaParser.shortGroupName("Gemini Models"), "Gemini")
    }

    func testAntigravityProcessClassification() {
        let ide = ProcessScanner.Entry(
            pid: 1,
            executablePath: "/Applications/Antigravity.app/Contents/Resources/app/extensions/antigravity/bin/language_server_macos_arm",
            arguments: ["language_server_macos_arm", "--csrf_token", "abc123", "--extension_server_port", "51000"]
        )
        let server = AntigravityServer.server(from: ide)
        XCTAssertEqual(server?.csrfToken, "abc123")
        XCTAssertEqual(server?.ports.first, 51000)

        let other = ProcessScanner.Entry(pid: 2, executablePath: "/Applications/Windsurf.app/bin/language_server_macos", arguments: ["--csrf_token=x"])
        XCTAssertNil(AntigravityServer.server(from: other))

        let tokenless = ProcessScanner.Entry(pid: 3, executablePath: "/Applications/Antigravity.app/bin/language_server", arguments: [])
        XCTAssertNil(AntigravityServer.server(from: tokenless))
    }

    func testAntigravityCLIDetection() {
        let live = ProcessScanner.Entry(pid: 9, executablePath: "/Users/me/.local/bin/agy", arguments: ["agy"])
        let renamedByUpdater = ProcessScanner.Entry(pid: 10, executablePath: "/Users/me/.local/bin/agy.1789692121374973000.old", arguments: ["agy", "--continue"])
        let unrelated = ProcessScanner.Entry(pid: 11, executablePath: "/usr/local/bin/agyxyz", arguments: ["agyxyz"])
        XCTAssertTrue(AntigravityServer.isCLI(live))
        XCTAssertTrue(AntigravityServer.isCLI(renamedByUpdater))
        XCTAssertFalse(AntigravityServer.isCLI(unrelated))
        XCTAssertNil(AntigravityServer.server(from: live), "CLI processes are never treated as queryable servers")
    }

    func testProcArgs2Parsing() {
        var bytes: [UInt8] = [2, 0, 0, 0]
        bytes += Array("/usr/bin/tool".utf8) + [0, 0, 0]
        bytes += Array("tool".utf8) + [0]
        bytes += Array("--flag=value".utf8) + [0]
        bytes += Array("HOME=/Users/x".utf8) + [0]
        XCTAssertEqual(ProcessScanner.parseProcArgs2(bytes), ["tool", "--flag=value"])
    }

    // MARK: Formatting

    func testResetFormatter() {
        XCTAssertEqual(ResetFormatter.text(for: now.addingTimeInterval(90), now: now), "Resets in 1m")
        XCTAssertEqual(ResetFormatter.text(for: now.addingTimeInterval(3600 * 2 + 60 * 14), now: now), "Resets in 2h 14m")
        XCTAssertEqual(ResetFormatter.text(for: now.addingTimeInterval(86_400 * 3 + 3600 * 5), now: now), "Resets in 3d 5h")
        XCTAssertEqual(ResetFormatter.text(for: now.addingTimeInterval(-5), now: now), "Resetting…")
        XCTAssertNil(ResetFormatter.text(for: nil))
        XCTAssertEqual(ResetFormatter.relative(now.addingTimeInterval(-120), now: now), "2m ago")
    }

    func testJWTDecoding() {
        let token = makeJWT(["sub": "abc", "exp": 1_800_000_000])
        XCTAssertEqual(JWT.string("sub", in: token), "abc")
        XCTAssertEqual(JWT.expiry(token), Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertNil(JWT.claims("garbage"))
    }

    // MARK: Helpers

    private func makeJWT(_ payload: [String: Any]) -> String {
        func encode(_ object: [String: Any]) -> String {
            let data = try! JSONSerialization.data(withJSONObject: object)
            return data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return "\(encode(["alg": "none"])).\(encode(payload)).sig"
    }
}
