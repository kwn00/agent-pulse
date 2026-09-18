import AppKit
import Darwin
import Foundation

/// Keeps exactly one Agent Pulse alive. A second launch asks the first one to open its panel, then exits.
///
/// Uses an advisory `flock` on a file in Application Support: it is released automatically when the
/// owning process dies, so a crash never leaves a stale lock behind.
@MainActor
enum SingleInstance {
    static let showPanelNotification = Notification.Name("dev.agentpulse.showPanel")

    private static var lockDescriptor: Int32 = -1
    private static var observer: NSObjectProtocol?

    private static var lockURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Agent Pulse/instance.lock")
    }

    /// Returns `false` when another instance already holds the lock (after nudging it to show its panel).
    /// `AGENTPULSE_ALLOW_MULTIPLE=1` skips the check so a dev build can run next to the installed app.
    static func acquire() -> Bool {
        if ProcessInfo.processInfo.environment["AGENTPULSE_ALLOW_MULTIPLE"] == "1" { return true }
        let url = lockURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let descriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return true } // Can't lock at all; better to run than to refuse.

        if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            close(descriptor)
            DistributedNotificationCenter.default().postNotificationName(
                showPanelNotification,
                object: nil,
                userInfo: nil,
                deliverImmediately: true
            )
            return false
        }

        lockDescriptor = descriptor
        return true
    }

    /// Lets the surviving instance react when a duplicate launch is refused.
    static func onShowRequest(_ handler: @escaping @MainActor () -> Void) {
        observer = DistributedNotificationCenter.default().addObserver(
            forName: showPanelNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { handler() }
        }
    }
}
