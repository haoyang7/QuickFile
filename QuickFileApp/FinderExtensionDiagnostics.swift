import Darwin
import Foundation
import QuickFileInfrastructure

enum ExtensionRegistration: String, Sendable {
    case registered, notRegistered, unknown
}

enum ExtensionRuntimeState: String, Sendable {
    case notEmbedded, notRegistered, disabled, responding, noResponse, unknown

    var displayName: String {
        switch self {
        case .notEmbedded: return "应用未嵌入 Finder 扩展"
        case .notRegistered: return "未找到扩展注册记录"
        case .disabled: return "扩展未获用户启用"
        case .responding: return "已启用，本次探针收到响应"
        case .noResponse: return "已启用，本次探针未收到响应"
        case .unknown: return "扩展状态未知"
        }
    }

    var recoveryGuidance: String? {
        guard self == .noResponse else { return nil }
        return "先在 Finder 中重新打开右键菜单，再检查响应。更新后可能仍有旧版扩展运行；请打开扩展设置，关闭再开启 QuickFile，然后重新检查。若仍未恢复，可在方便时重启 Finder。扩展进程由 macOS 管理，重开主 App 不保证重启扩展。"
    }
}

struct FinderExtensionDiagnosticSnapshot: Sendable {
    let embeddedIdentifiers: [String]
    let embeddingKnown: Bool
    let registration: ExtensionRegistration
    let registrationEvidence: String
    let enabled: Bool
    let responded: Bool?

    var state: ExtensionRuntimeState {
        guard embeddingKnown else { return .unknown }
        guard !embeddedIdentifiers.isEmpty else { return .notEmbedded }
        if enabled {
            guard let responded else { return .unknown }
            return responded ? .responding : .noResponse
        }
        switch registration {
        case .registered: return .disabled
        case .notRegistered: return .notRegistered
        case .unknown: return .unknown
        }
    }
}

enum FinderExtensionRuntimeInspector {
    @MainActor
    static func snapshot(
        enabled: Bool,
        probe: (URL) async -> Bool = { await FinderExtensionProbe.check(extensionURL: $0) },
        registrationQuery: @escaping @Sendable (String, URL?) -> (ExtensionRegistration, String) = {
            FinderExtensionInstallationInspector.registration(identifier: $0, pluginDirectory: $1)
        }
    ) async -> FinderExtensionDiagnosticSnapshot {
        let installation = await BackgroundWork.run {
            FinderExtensionInstallationInspector.inspect()
        }
        let response: Bool?
        if enabled, let extensionURL = installation.extensionURL {
            response = await probe(extensionURL)
        } else {
            response = nil
        }
        let registration: (ExtensionRegistration, String)
        if response == true {
            // The path-bound probe is the runtime evidence. A successful response
            // does not claim that an independent system-registration query ran.
            registration = (.unknown, "本次探针收到当前安装副本及版本的响应；未单独查询系统注册记录。")
        } else {
            registration = await BackgroundWork.run {
                installation.identifiers.first.map {
                    registrationQuery($0, Bundle.main.builtInPlugInsURL)
                } ?? (.unknown, "没有可查询的嵌入扩展标识。")
            }
        }
        return FinderExtensionDiagnosticSnapshot(
            embeddedIdentifiers: installation.identifiers, embeddingKnown: installation.known,
            registration: registration.0, registrationEvidence: registration.1,
            enabled: enabled, responded: response
        )
    }
}

// All disk/process access is performed by the caller on BackgroundWork, never on the UI thread.
enum FinderExtensionInstallationInspector {
    static func inspect(bundle: Bundle = .main) -> (identifiers: [String], known: Bool, extensionURL: URL?) {
        guard let plugins = bundle.builtInPlugInsURL else { return ([], true, nil) }
        do {
            let urls = try FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil)
            var metadataReadable = true
            var primaryURL: URL?
            let identifiers = urls.filter { $0.pathExtension == "appex" }.compactMap { url -> String? in
                guard let extensionBundle = Bundle(url: url),
                      let extensionInfo = extensionBundle.infoDictionary?["NSExtension"] as? [String: Any],
                      extensionInfo["NSExtensionPointIdentifier"] as? String == "com.apple.FinderSync"
                else {
                    if Bundle(url: url)?.infoDictionary == nil { metadataReadable = false }
                    return nil
                }
                guard let identifier = extensionBundle.bundleIdentifier else {
                    metadataReadable = false
                    return nil
                }
                if primaryURL == nil { primaryURL = url }
                return identifier
            }
            return (identifiers, metadataReadable, primaryURL)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return ([], true, nil)
        } catch { return ([], false, nil) }
    }

    static func registration(identifier: String, pluginDirectory: URL?) -> (ExtensionRegistration, String) {
        let result = RegistrationCommand.run(
            executable: "/usr/bin/pluginkit", arguments: ["-m", "-A", "-D", "-v", "-i", identifier]
        )
        switch result {
        case let .success(exitCode, data):
            guard let text = String(data: data, encoding: .utf8) else {
                return (.unknown, "pluginkit 输出无法解码。请在终端检查注册记录。")
            }
            return interpretRegistration(exitCode: exitCode, output: text, identifier: identifier, pluginDirectory: pluginDirectory)
        case .failure(.launch):
            return (.unknown, "pluginkit 无法执行，可能受沙盒限制。请在终端用 pluginkit -m -A -D -v -i 检查下列嵌入标识。")
        case .failure(.timeout):
            return (.unknown, "pluginkit 查询超时。请打开扩展管理，或在终端检查注册状态。")
        case .failure(.outputLimit):
            return (.unknown, "pluginkit 输出超过大小限制。请在终端检查注册记录。")
        case .failure(.io):
            return (.unknown, "pluginkit 输出读取失败。请在终端检查注册记录。")
        case .failure(.busy):
            return (.unknown, "已有扩展查询正在执行或等待回收，请稍后重试。")
        case .failure(.cleanup):
            return (.unknown, "pluginkit 查询终止后未能确认退出。请在终端检查注册状态。")
        }
    }

    static func interpretRegistration(exitCode: Int32, output: String, identifier: String, pluginDirectory: URL? = nil) -> (ExtensionRegistration, String) {
        guard exitCode == 0 else {
            let message: String
            let error = output.lowercased()
            if error.contains("operation not permitted") || error.contains("permission denied") || error.contains("not allowed") {
                message = "系统拒绝访问注册信息，可能受沙盒或系统访问限制。"
            } else if error.contains("connection invalid") || error.contains("connection interrupted") || error.contains("could not connect") || error.contains("connection refused") {
                message = "无法连接系统扩展注册服务。"
            } else {
                message = "未能确认原因，退出码不能用于判断扩展是否已注册或启用。"
            }
            // Do not expose raw output: it can contain private filesystem paths.
            return (.unknown, "App 内注册查询未完成（退出码 \(exitCode)）。\(message)可打开扩展管理，或在终端核对注册记录。")
        }
        var matchingRecord = false
        var foundIdentifier = false
        for line in output.split(whereSeparator: \.isNewline) {
            let text = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            let tokens = line.split(whereSeparator: \.isWhitespace)
            let hasIdentifier = tokens.contains { $0 == identifier || $0.hasPrefix(identifier + "(") }
            // A record header has a versioned bundle identifier; following indented path belongs to it.
            if !text.hasPrefix("/"), tokens.contains(where: { $0.contains("(") && $0.contains(".") }) {
                matchingRecord = hasIdentifier
            }
            if hasIdentifier { matchingRecord = true; foundIdentifier = true }
            if matchingRecord, let pluginDirectory {
                // In verbose output the absolute path is either the final field of a
                // record header or a standalone indented line. Preserve all spaces and
                // the entire leading path, including backup-volume prefixes.
                if let start = text.firstIndex(of: "/"),
                   (text.hasPrefix("/") || hasIdentifier) {
                    let registeredURL = URL(fileURLWithPath: String(text[start...])).standardizedFileURL
                    if registeredURL.pathExtension == "appex",
                       registeredURL.deletingLastPathComponent().path == pluginDirectory.standardizedFileURL.path {
                        return (.registered, "pluginkit 查询成功，找到当前应用内扩展路径的注册记录。")
                    }
                }
            }
        }
        if foundIdentifier {
            return (.unknown, "找到同 Bundle ID 的注册记录，但无法确认属于当前应用副本。请在终端核对 pluginkit 输出中的路径。")
        }
        if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return (.notRegistered, "pluginkit 查询成功，未返回匹配记录。请从应用程序目录启动 QuickFile，再打开扩展管理。")
        }
        return (.unknown, "pluginkit 输出无法识别。请在终端检查注册记录。")
    }
}

// Synchronous, bounded work; production callers run this on BackgroundWork.
// Own waitpid rather than Process's automatic reaper: an exited but unreaped child
// keeps its PID reserved, so timeout signals cannot target a recycled PID.
enum RegistrationCommand {
    enum Failure: Equatable { case launch, timeout, outputLimit, io, cleanup, busy }
    enum Result {
        case success(Int32, Data)
        case failure(Failure)
    }

    // A slot covers both execution and any deferred reaping. Even an uninterruptible
    // child cannot cause repeated refreshes to accumulate processes or reaper workers.
    private static let slots = DispatchSemaphore(value: 2)
    private static let reapers = DispatchQueue(label: "com.haoyoung.QuickFile.registration-reapers",
                                               qos: .utility, attributes: .concurrent)

    static func run(executable: String, arguments: [String], timeout: TimeInterval = 2,
                    maximumOutputBytes: Int = 1_048_576,
                    waitForChild: @escaping @Sendable (pid_t, UnsafeMutablePointer<Int32>, Int32) -> pid_t = {
                        Darwin.waitpid($0, $1, $2)
                    }) -> Result {
        guard slots.wait(timeout: .now()) == .success else { return .failure(.busy) }
        var transferredSlot = false
        defer { if !transferredSlot { slots.signal() } }
        var descriptors: [Int32] = [-1, -1]
        guard pipe(&descriptors) == 0 else { return .failure(.io) }
        let reader = descriptors[0]
        let writer = descriptors[1]
        defer { close(reader) }
        // CLOEXEC also prevents another concurrently spawned command retaining these FDs.
        guard fcntl(reader, F_SETFD, FD_CLOEXEC) == 0,
              fcntl(writer, F_SETFD, FD_CLOEXEC) == 0,
              fcntl(reader, F_SETFL, O_NONBLOCK) == 0 else {
            close(writer)
            return .failure(.io)
        }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            close(writer)
            return .failure(.launch)
        }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else {
            close(writer)
            return .failure(.launch)
        }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0,
              posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) == 0,
              posix_spawn_file_actions_adddup2(&actions, writer, STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, writer, STDERR_FILENO) == 0 else {
            close(writer)
            return .failure(.launch)
        }
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        let environment = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { environment.forEach { free($0) } }
        var child: pid_t = 0
        let launched = argv.withUnsafeBufferPointer { argvBuffer in
            environment.withUnsafeBufferPointer { environmentBuffer in
                posix_spawn(&child, executable, &actions, &attributes, argvBuffer.baseAddress!, environmentBuffer.baseAddress!)
            }
        }
        close(writer)
        guard launched == 0 else { return .failure(.launch) }

        var status: Int32 = 0
        var reaped = false
        var waitFailed = false
        func checkExit() {
            guard !reaped && !waitFailed else { return }
            let result = waitForChild(child, &status, WNOHANG)
            if result == child { reaped = true }
            else if result < 0 && errno != EINTR { waitFailed = true }
        }
        func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
        func waitForExit(until deadline: TimeInterval) {
            while !reaped && !waitFailed && now() < deadline {
                checkExit()
                if !reaped && !waitFailed { _ = poll(nil, 0, 5) }
            }
            checkExit()
        }
        func fail(_ failure: Failure) -> Result {
            checkExit()
            // Never signal if ownership was lost (e.g. ECHILD), or after reaping.
            if !reaped && !waitFailed {
                _ = kill(child, SIGTERM)
                waitForExit(until: now() + 0.1)
            }
            if !reaped && !waitFailed {
                _ = kill(child, SIGKILL)
                waitForExit(until: now() + 0.5)
            }
            if !reaped && !waitFailed {
                // Transfer the sole waitpid ownership together with the occupied slot.
                // Capture only the PID and syscall, never the output buffer or pipe.
                transferredSlot = true
                let ownedChild = child
                reapers.async {
                    defer { slots.signal() }
                    var finalStatus: Int32 = 0
                    while waitForChild(ownedChild, &finalStatus, 0) < 0 {
                        if errno != EINTR { break } // ECHILD means ownership is already gone.
                    }
                }
            }
            return .failure(reaped ? failure : .cleanup)
        }

        let deadline = now() + max(0, timeout)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        var eof = false
        while true {
            checkExit()
            if waitFailed { return fail(.io) }
            if eof && reaped {
                // Darwin's wait-status macros are not imported into Swift.
                let signal = status & 0x7f
                let exitCode = signal == 0 ? (status >> 8) & 0xff : 128 + signal
                return .success(exitCode, data)
            }
            if now() >= deadline { return fail(.timeout) }
            if !eof {
                let count = read(reader, &buffer, buffer.count)
                if count > 0 {
                    guard count <= maximumOutputBytes - data.count else { return fail(.outputLimit) }
                    data.append(contentsOf: buffer.prefix(count))
                    continue // Recheck deadline even under continuously available output.
                }
                if count == 0 { eof = true; continue }
                if errno == EINTR { continue }
                if errno != EAGAIN && errno != EWOULDBLOCK { return fail(.io) }
            }
            // No reader thread or blocking read survives return, even if a descendant
            // retains stdout after the direct child exits. Only our two FDs are closed.
            var descriptor = pollfd(fd: eof ? -1 : reader, events: Int16(POLLIN), revents: 0)
            let milliseconds = Int32(max(1, min(10, (deadline - now()) * 1_000)))
            let polled = poll(&descriptor, 1, milliseconds)
            if polled < 0 && errno != EINTR { return fail(.io) }
            if descriptor.revents & Int16(POLLNVAL) != 0 { return fail(.io) }
        }
    }
}
