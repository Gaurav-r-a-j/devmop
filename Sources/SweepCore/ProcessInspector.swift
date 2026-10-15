import Darwin
import Foundation

public struct RunningProcess: Hashable, Sendable {
    public let pid: Int32
    public let name: String
    public let workingDirectory: String
}

/// Lists the current user's processes and their working folders.
public enum ProcessInspector {
    public static func runningProcesses() -> [RunningProcess] {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(capacity) + 64)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return [] }

        let ownPID = getpid()
        var result: [RunningProcess] = []
        for pid in pids.prefix(Int(count)) where pid > 0 && pid != ownPID {
            var info = proc_vnodepathinfo()
            let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { continue }

            let cwd = withUnsafeBytes(of: info.pvi_cdir.vip_path) { bytes in
                String(cString: bytes.bindMemory(to: CChar.self).baseAddress!)
            }
            guard cwd.count > 1 else { continue }
            result.append(RunningProcess(pid: pid, name: name(of: pid), workingDirectory: cwd))
        }
        return result
    }

    public static func processNames() -> Set<String> {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(capacity) + 64)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return Set(pids.prefix(Int(max(count, 0))).filter { $0 > 0 }.map(name(of:)))
    }

    static let shells: Set<String> = ["zsh", "bash", "fish", "sh", "dash", "tcsh", "nu", "login", "tmux", "screen", "-zsh", "-bash"]

    /// The first non-shell process whose working folder is inside `path`.
    public static func user(of path: String, among processes: [RunningProcess]) -> RunningProcess? {
        processes.first { !shells.contains($0.name) && $0.workingDirectory.isInside(path) }
    }

    /// A terminal shell whose working folder is inside `path`.
    public static func shell(in path: String, among processes: [RunningProcess]) -> RunningProcess? {
        processes.first { shells.contains($0.name) && $0.workingDirectory.isInside(path) }
    }

    private static func name(of pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        return length > 0 ? String(cString: buffer) : "process \(pid)"
    }
}
