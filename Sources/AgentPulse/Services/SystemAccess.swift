import Foundation

enum Shell {
    struct Output: Sendable {
        var stdout: String
        var status: Int32
    }

    /// Runs an executable and captures stdout. Runs off the cooperative pool since `Process` blocks.
    static func run(_ executable: String, _ arguments: [String]) async throws -> Output {
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return Output(stdout: String(decoding: data, as: UTF8.self), status: process.terminationStatus)
        }.value
    }
}

enum JWT {
    /// Decodes the payload of a JWT without verifying its signature.
    static func claims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        guard let data = Data(base64Encoded: base64),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    static func string(_ key: String, in token: String) -> String? {
        claims(token)?[key] as? String
    }

    static func expiry(_ token: String) -> Date? {
        guard let exp = claims(token)?["exp"] as? Double else { return nil }
        return Date(timeIntervalSince1970: exp)
    }
}

enum Paths {
    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    static func expand(_ path: String) -> URL {
        if path.hasPrefix("~") {
            return home.appendingPathComponent(String(path.dropFirst(2)))
        }
        return URL(fileURLWithPath: path)
    }

    static func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: expand(path).path)
    }
}
