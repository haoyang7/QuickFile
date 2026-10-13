import Darwin
import Foundation

private enum Fault {
    static var scenario = ""
    static var root: URL!
    static var openInjected = false
    static var identityInjected = false
}

// Same-module overloads inject faults into the unmodified production source.
// Normal and EMFILE cases still execute Darwin.openat; no production test hook.
func openat(_ parent: Int32, _ name: String, _ flags: Int32) -> Int32 {
    if name.hasPrefix(".quickfile-write-probe-"), !Fault.openInjected,
       Fault.scenario.hasPrefix("replacement-") || Fault.scenario == "nonempty" {
        Fault.openInjected = true
        let url = Fault.root.appendingPathComponent(name)
        do {
            if Fault.scenario.hasPrefix("replacement-") {
                try FileManager.default.moveItem(at: url, to: Fault.root.appendingPathComponent("moved"))
                if Fault.scenario == "replacement-file" {
                    try "sentinel".write(to: url, atomically: false, encoding: .utf8)
                } else {
                    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                }
            }
            if Fault.scenario == "nonempty" || Fault.scenario == "replacement-nonempty" {
                try "sentinel".write(to: url.appendingPathComponent("keep.txt"), atomically: false, encoding: .utf8)
            }
        } catch { fatalError("Owned fault setup failed: \(error)") }
        if Fault.scenario == "replacement-opened" { return Darwin.openat(parent, name, flags) }
        errno = EIO
        return -1
    }
    return Darwin.openat(parent, name, flags)
}

func fstatat(_ parent: Int32, _ name: String, _ value: UnsafeMutablePointer<stat>, _ flags: Int32) -> Int32 {
    if Fault.scenario == "identity-unavailable", !Fault.identityInjected,
       name.hasPrefix(".quickfile-write-probe-") {
        Fault.identityInjected = true
        errno = EIO
        return -1
    }
    return Darwin.fstatat(parent, name, value, flags)
}

@main
struct StagingFailureCases {
    static func main() throws {
        Fault.scenario = CommandLine.arguments[1]
        Fault.root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        precondition(chmod(Fault.root.path, 0o700) == 0)
        let parent = open(Fault.root.path, O_SEARCH | O_CLOEXEC)
        precondition(parent >= 0)
        defer { close(parent) }

        var originalLimit = rlimit()
        var occupied = [Int32]()
        if Fault.scenario == "fd-exhausted" {
            precondition(getrlimit(RLIMIT_NOFILE, &originalLimit) == 0)
            var limited = originalLimit
            limited.rlim_cur = min(originalLimit.rlim_cur, 64)
            precondition(setrlimit(RLIMIT_NOFILE, &limited) == 0)
            while true {
                let descriptor = open("/dev/null", O_RDONLY | O_CLOEXEC)
                if descriptor < 0 { precondition(errno == EMFILE); break }
                occupied.append(descriptor)
            }
            precondition(!occupied.isEmpty)
            close(occupied.removeLast()) // The parent dup succeeds; opening the new directory fails.
        }

        var failure: NSError?
        do {
            let staging = try PrivateFileStagingDirectory.probeDirectory(in: parent, folderURL: Fault.root)
            try staging.remove()
        } catch { failure = error as NSError }
        for descriptor in occupied { close(descriptor) }
        if Fault.scenario == "fd-exhausted" {
            precondition(setrlimit(RLIMIT_NOFILE, &originalLimit) == 0)
        }

        var errors = [[String: Any]]()
        var current = failure
        while let error = current {
            errors.append(["domain": error.domain, "code": error.code])
            current = error.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        var entries = [String: Any]()
        var sentinelIntact = true
        for entry in try FileManager.default.contentsOfDirectory(at: Fault.root, includingPropertiesForKeys: nil) {
            let label = entry.lastPathComponent.hasPrefix(".quickfile-write-probe-") ? "staging" : entry.lastPathComponent
            var metadata = stat()
            precondition(lstat(entry.path, &metadata) == 0)
            if metadata.st_mode & S_IFMT == S_IFDIR {
                let children = try FileManager.default.contentsOfDirectory(atPath: entry.path).sorted()
                entries[label] = children
                if children.contains("keep.txt") {
                    let contents = try String(contentsOf: entry.appendingPathComponent("keep.txt"), encoding: .utf8)
                    sentinelIntact = sentinelIntact && contents == "sentinel"
                }
            } else {
                let contents = try String(contentsOf: entry, encoding: .utf8)
                entries[label] = contents
                sentinelIntact = sentinelIntact && contents == "sentinel"
            }
        }
        let result: [String: Any] = ["errors": errors, "entries": entries,
            "parent_open": fcntl(parent, F_GETFD) >= 0, "sentinel_intact": sentinelIntact,
            "cleanup_failed": failure?.localizedDescription.contains("清理未完成") == true]
        print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
    }
}
