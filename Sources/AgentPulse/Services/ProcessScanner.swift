import Darwin
import Foundation

/// In-process replacement for `ps` + `lsof`, built on libproc / sysctl.
enum ProcessScanner {
    struct Entry: Sendable {
        var pid: pid_t
        var executablePath: String
        var arguments: [String]

        var commandLine: String { arguments.joined(separator: " ") }

        /// Value of `--flag value` or `--flag=value`.
        func flag(_ name: String) -> String? {
            for (index, argument) in arguments.enumerated() {
                if argument == name, index + 1 < arguments.count { return arguments[index + 1] }
                if argument.hasPrefix(name + "=") { return String(argument.dropFirst(name.count + 1)) }
            }
            return nil
        }
    }

    static func allPIDs() -> [pid_t] {
        let required = proc_listallpids(nil, 0)
        guard required > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(required) + 64)
        let filled = pids.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        guard filled > 0 else { return [] }
        return Array(pids.prefix(Int(filled))).filter { $0 > 0 }
    }

    static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let bytes = buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Reads argv via `KERN_PROCARGS2`, stopping before the environment block.
    static func arguments(_ pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else {
            return nil
        }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &size, nil, 0) == 0 else { return nil }
        return parseProcArgs2(Array(buffer.prefix(size)))
    }

    static func parseProcArgs2(_ bytes: [UInt8]) -> [String]? {
        guard bytes.count > 4 else { return nil }
        let argc = Int(bytes[0]) | Int(bytes[1]) << 8 | Int(bytes[2]) << 16 | Int(bytes[3]) << 24
        var index = 4
        while index < bytes.count, bytes[index] != 0 { index += 1 }
        while index < bytes.count, bytes[index] == 0 { index += 1 }

        var arguments: [String] = []
        while arguments.count < argc, index < bytes.count {
            var end = index
            while end < bytes.count, bytes[end] != 0 { end += 1 }
            arguments.append(String(decoding: bytes[index..<end], as: UTF8.self))
            index = end + 1
        }
        return arguments
    }

    /// Processes whose executable path passes `pathFilter`, with argv resolved.
    static func entries(where pathFilter: (String) -> Bool) -> [Entry] {
        var result: [Entry] = []
        for pid in allPIDs() {
            guard let path = executablePath(pid), pathFilter(path) else { continue }
            guard let arguments = arguments(pid) else { continue }
            result.append(Entry(pid: pid, executablePath: path, arguments: arguments))
        }
        return result
    }

    static func listeningTCPPorts(_ pid: pid_t) -> [Int] {
        let requiredBytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard requiredBytes > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(requiredBytes) / stride + 16)
        let actualBytes = descriptors.withUnsafeMutableBytes { buffer in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buffer.baseAddress, Int32(buffer.count))
        }
        guard actualBytes > 0 else { return [] }

        var ports = Set<Int>()
        let socketSize = Int32(MemoryLayout<socket_fdinfo>.size)
        for descriptor in descriptors.prefix(Int(actualBytes) / stride)
        where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let bytes = proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &info, socketSize)
            guard bytes == socketSize, info.psi.soi_kind == SOCKINFO_TCP else { continue }
            let tcp = info.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == TSI_S_LISTEN else { continue }
            let rawPort = UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport)
            ports.insert(Int(UInt16(bigEndian: rawPort)))
        }
        return ports.sorted()
    }
}
