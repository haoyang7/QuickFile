import Darwin
import XCTest
@testable import QuickFile
import QuickFileInfrastructure

final class FinderExtensionDiagnosticsTests: XCTestCase {
    @MainActor
    func testRespondingInstallationDoesNotRequireRegistrationCommand() async {
        let result = await FinderExtensionRuntimeInspector.snapshot(
            enabled: true,
            probe: { _ in true },
            registrationQuery: { _, _ in
                XCTFail("A responding extension should not need a sandboxed system query")
                return (.unknown, "query failed")
            }
        )
        XCTAssertEqual(result.state, .responding)
        XCTAssertEqual(result.registration, .unknown)
        XCTAssertTrue(result.registrationEvidence.contains("未单独查询"))
    }

    @MainActor
    func testUnresponsiveInstallationRetainsIndependentRegistrationEvidence() async {
        let result = await FinderExtensionRuntimeInspector.snapshot(
            enabled: true, probe: { _ in false },
            registrationQuery: { _, _ in (.registered, "queried registration") }
        )
        XCTAssertEqual(result.state, .noResponse)
        XCTAssertEqual(result.registration, .registered)
        XCTAssertEqual(result.registrationEvidence, "queried registration")
    }

    func testRegistrationFailureDistinguishesAccessServiceAndUnknownErrorsWithoutLeakingPaths() {
        let identifier = "com.haoyoung.QuickFile.FinderExtension"
        for (output, expected) in [
            ("Permission denied: /Users/private-user/secret", "系统拒绝访问"),
            ("XPC connection invalid: /Users/private-user/secret", "无法连接系统"),
            ("unrecognized failure: /Users/private-user/secret", "未能确认原因"),
            ("", "未能确认原因")
        ] {
            let result = FinderExtensionInstallationInspector.interpretRegistration(
                exitCode: 1, output: output, identifier: identifier
            )
            XCTAssertEqual(result.0, .unknown)
            XCTAssertTrue(result.1.contains(expected), result.1)
            XCTAssertFalse(result.1.contains("/Users/"))
        }
    }

    func testAuthorizationSearchCombinesPathMatchingWithAttentionFilter() {
        let healthy = AuthorizedDirectory(id: UUID(), url: URL(fileURLWithPath: "/Volumes/Work/Project Alpha"), isBookmarkStale: false)
        let stale = AuthorizedDirectory(id: UUID(), url: URL(fileURLWithPath: "/Volumes/Work/旧项目"), isBookmarkStale: true)
        XCTAssertTrue(AuthorizationListFilter.all.matches(healthy, search: "  alpha \n"))
        XCTAssertTrue(AuthorizationListFilter.all.matches(healthy, search: "/volumes/work"))
        XCTAssertFalse(AuthorizationListFilter.needsAttention.matches(healthy, search: ""))
        XCTAssertTrue(AuthorizationListFilter.needsAttention.matches(stale, search: "旧项目"))
        XCTAssertFalse(AuthorizationListFilter.needsAttention.matches(stale, search: "alpha"))
        let unavailable = UnavailableAuthorizedDirectory(id: UUID())
        XCTAssertTrue(AuthorizationListFilter.needsAttention.matches(unavailable, search: ""))
        XCTAssertTrue(AuthorizationListFilter.all.matches(unavailable, search: unavailable.id.uuidString.lowercased()))
        XCTAssertFalse(AuthorizationListFilter.all.matches(unavailable, search: "alpha"))
    }

    func testRuntimeStatesKeepIndependentEvidence() {
        XCTAssertEqual(snapshot(identifiers: []).state, .notEmbedded)
        XCTAssertEqual(snapshot(known: false).state, .unknown)
        XCTAssertEqual(snapshot(registration: .notRegistered).state, .notRegistered)
        XCTAssertEqual(snapshot(registration: .registered).state, .disabled)
        XCTAssertEqual(snapshot(registration: .unknown).state, .unknown)
        XCTAssertEqual(snapshot(registration: .unknown, enabled: true, responded: false).state, .noResponse)
        XCTAssertEqual(snapshot(enabled: true, responded: true).state, .responding)
        XCTAssertEqual(snapshot(enabled: true, responded: nil).state, .unknown)
    }

    func testRegistrationRequiresSuccessfulQueryAndCurrentInstallation() {
        let directory = URL(fileURLWithPath: "/Applications/QuickFile.app/Contents/PlugIns")
        let identifier = "com.haoyoung.QuickFile.FinderExtension"
        let currentOutput = "+ \(identifier)(1.0)\n    \(directory.path)/FinderExtension.appex\n"
        let inspect = FinderExtensionInstallationInspector.interpretRegistration
        XCTAssertEqual(inspect(0, currentOutput, identifier, directory).0, .registered)
        XCTAssertEqual(inspect(0, "+ \(identifier)(1.0)\tUUID\t2026-09-26 03:15:12 +0000\t\(directory.path)/FinderExtension.appex\n (1 plug-in)", identifier, directory).0, .registered)
        XCTAssertEqual(inspect(0, "+ \(identifier)(1.0)\n /old/FinderExtension.appex\n + other.extension(1.0)\n \(directory.path)/Other.appex", identifier, directory).0, .unknown)
        XCTAssertEqual(inspect(1, "", identifier, directory).0, .unknown)
        XCTAssertEqual(inspect(0, "", identifier, directory).0, .notRegistered)
        XCTAssertEqual(inspect(0, "unexpected output", identifier, directory).0, .unknown)
        XCTAssertEqual(inspect(0, "+ \(identifier)(1.0)\n /old/QuickFile.app/Contents/PlugIns/FinderExtension.appex", identifier, directory).0, .unknown)
    }

    func testRegistrationComparesCompleteParentPathsIncludingSpaces() {
        let identifier = "com.haoyoung.QuickFile.FinderExtension"
        for appName in ["QuickFile.app", "Quick File.app"] {
            let directory = URL(fileURLWithPath: "/Applications/\(appName)/Contents/PlugIns")
            let actualPath = directory.appendingPathComponent("Finder Extension.appex").path
            for path in [actualPath, "/Volumes/Backup" + actualPath] {
                let expected: ExtensionRegistration = path == actualPath ? .registered : .unknown
                for output in [
                    "+ \(identifier)(1.0)\tUUID\t2026-09-26 03:15:12 +0000\t\(path)\n (1 plug-in)",
                    "+ \(identifier)(1.0)\n    \(path)\n"
                ] {
                    XCTAssertEqual(FinderExtensionInstallationInspector.interpretRegistration(
                        exitCode: 0, output: output, identifier: identifier, pluginDirectory: directory
                    ).0, expected, output)
                }
            }
        }
    }

    func testMissingPluginDirectoryIsNotEmbedded() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("app")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let info: [String: String] = ["CFBundleIdentifier": "test.empty", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: root.appendingPathComponent("Contents/Info.plist"))
        let result = FinderExtensionInstallationInspector.inspect(bundle: try XCTUnwrap(Bundle(url: root)))
        XCTAssertTrue(result.known)
        XCTAssertTrue(result.identifiers.isEmpty)
    }

    func testCommandDrainsLargeOutputWithoutPipeDeadlock() {
        let start = ProcessInfo.processInfo.systemUptime
        let result = RegistrationCommand.run(executable: "/bin/sh", arguments: ["-c",
            "/bin/dd if=/dev/zero bs=65536 count=8 2>/dev/null"], timeout: 2)
        guard case let .success(code, output) = result else { return XCTFail("Expected successful output") }
        XCTAssertEqual(code, 0)
        XCTAssertEqual(output.count, 524_288)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 2.5)
    }

    func testCommandCapsOutput() {
        let result = RegistrationCommand.run(executable: "/bin/sh", arguments: ["-c",
            "while :; do printf '0123456789abcdef'; done"], timeout: 2, maximumOutputBytes: 1_024)
        assertFailure(result, .outputLimit)
    }

    func testCommandReapsChildIgnoringTERMWithinBound() throws {
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let start = ProcessInfo.processInfo.systemUptime
        let result = RegistrationCommand.run(executable: "/bin/sh", arguments: ["-c",
            "trap '' TERM; echo $$ > '\(pidFile.path)'; while :; do :; done"], timeout: 0.2)
        assertFailure(result, .timeout)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1.2)
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile).trimmingCharacters(in: .whitespacesAndNewlines)))
        // waitpid proves the child has been reaped, without signalling a potentially reused PID.
        var status: Int32 = 0
        XCTAssertEqual(waitpid(pid, &status, WNOHANG), -1)
        XCTAssertEqual(errno, ECHILD)
    }

    func testCommandClosesReaderWhenDescendantRetainsOutput() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let readyPath = directory.appendingPathComponent("ready").path
        let releasePath = directory.appendingPathComponent("release").path
        XCTAssertEqual(mkfifo(readyPath, 0o600), 0)
        XCTAssertEqual(mkfifo(releasePath, 0o600), 0)
        let ready = open(readyPath, O_RDWR | O_NONBLOCK | O_CLOEXEC)
        guard ready >= 0 else { return XCTFail("Cannot open helper readiness FIFO") }
        defer { close(ready) }
        let release = open(releasePath, O_RDWR | O_NONBLOCK | O_CLOEXEC)
        guard release >= 0 else { return XCTFail("Cannot open helper release FIFO") }
        defer { close(release) }
        let exits = kqueue()
        guard exits >= 0 else { return XCTFail("Cannot observe helper exit") }
        defer { close(exits) }
        let handshake = DescendantHandshake(ready: ready, exits: exits)
        func releaseHelper() {
            var byte: UInt8 = 10
            XCTAssertEqual(write(release, &byte, 1), 1)
        }
        defer {
            releaseHelper()
            // Recover a late readiness message on failure before removing the FIFOs.
            if handshake.pid == nil { handshake.observeReadiness(timeout: 6) }
            if handshake.pid != nil && !handshake.exited {
                XCTAssertTrue(handshake.waitForExit(timeout: 6), "Helper did not exit during cleanup")
            }
        }
        let helper = """
            exec 3<> "$1" 4<> "$2" || exit 1
            printf '%s\\n' "$$" >&3
            IFS= read -r -t 5 release <&4 || exit 1
            trap '' PIPE
            if printf retained 2>/dev/null; then
                /usr/bin/printf 'reader-open\\n' >&3
            else
                /usr/bin/printf 'survived\\n' >&3
            fi
            """
        let started = ProcessInfo.processInfo.systemUptime
        let result = RegistrationCommand.run(executable: "/bin/sh", arguments: ["-c",
            "/bin/sh -c \"$1\" helper \"$2\" \"$3\" & exit 0", "command", helper, readyPath, releasePath],
            timeout: 0.1, waitForChild: { handshake.wait(pid: $0, status: $1, options: $2) })
        assertFailure(result, .timeout)
        let readyAt = try XCTUnwrap(handshake.readyAt, "Descendant never retained the output pipe")
        XCTAssertLessThan(readyAt - started, 3, "Fixture readiness exceeded its bound")
        // The deadline already exists at the first waitpid check. Startup can consume
        // that deadline, but a live descendant still holds stdout until we release it.
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - readyAt, 0.4)
        releaseHelper()
        XCTAssertEqual(DescendantHandshake.readMessage(from: ready, timeout: 3), "survived")
        XCTAssertTrue(handshake.waitForExit(timeout: 3), "Helper did not exit after release")
    }

    func testCommandLaunchFailure() {
        assertFailure(RegistrationCommand.run(executable: "/nonexistent/quickfile-test-helper", arguments: []), .launch)
    }

    func testCommandRepeatedFailuresDoNotLeakDescriptors() {
        func descriptors() -> Set<Int32> {
            Set((0..<4096).map(Int32.init).filter { fcntl($0, F_GETFD) >= 0 })
        }
        // Warm up Foundation before recording the FD baseline.
        _ = RegistrationCommand.run(executable: "/bin/sh", arguments: ["-c", "exit 0"])
        let before = descriptors()
        for _ in 0..<8 {
            assertFailure(RegistrationCommand.run(executable: "/bin/sh", arguments: ["-c",
                "trap '' TERM; while :; do :; done"], timeout: 0.05), .timeout)
            assertFailure(RegistrationCommand.run(executable: "/nonexistent/quickfile-test-helper", arguments: []), .launch)
        }
        XCTAssertTrue(descriptors().subtracting(before).isEmpty)
    }

    func testCommandPreservesNonzeroExitAndCombinedOutput() {
        let result = RegistrationCommand.run(executable: "/bin/sh", arguments: ["-c",
            "printf out; printf err >&2; exit 7"])
        guard case let .success(code, output) = result else { return XCTFail("Expected captured command result") }
        XCTAssertEqual(code, 7)
        XCTAssertEqual(String(decoding: output, as: UTF8.self), "outerr")
    }

    func testCommandTransfersReapingOwnershipAndBoundsPendingCleanup() {
        let gates = [DelayedReap(), DelayedReap()]
        defer { gates.forEach { $0.resume.signal() } }
        let started = ProcessInfo.processInfo.systemUptime
        for gate in gates {
            let result = RegistrationCommand.run(executable: "/bin/sh", arguments: ["-c", "exit 0"],
                timeout: 0.01, waitForChild: { gate.wait(pid: $0, status: $1, options: $2) })
            assertFailure(result, .cleanup)
            XCTAssertEqual(gate.entered.wait(timeout: .now() + 1), .success)
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 2)
        XCTAssertNotEqual(gates[0].pid, gates[1].pid)
        // Both calls returned, but their slots still belong to the deferred reapers.
        for _ in 0..<8 {
            assertFailure(RegistrationCommand.run(executable: "/bin/sh", arguments: ["-c", "exit 0"]), .busy)
        }
        gates.forEach { $0.resume.signal() }
        for gate in gates {
            XCTAssertEqual(gate.finished.wait(timeout: .now() + 1), .success)
            XCTAssertEqual(gate.result, gate.pid)
            var status: Int32 = 0
            XCTAssertEqual(waitpid(gate.pid, &status, WNOHANG), -1)
            XCTAssertEqual(errno, ECHILD)
        }
        // The test syscall returns just before the reaper releases its slot.
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while true {
            let result = RegistrationCommand.run(executable: "/bin/sh", arguments: ["-c", "exit 0"])
            if case .success(0, _) = result { break }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                return XCTFail("Reaping did not release command capacity")
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
    }

    // This test calls run synchronously. Its first wait sets checkedReadiness before
    // run can publish the callback to a deferred reaper; the flag never changes again.
    // Deferred calls only read that published flag and call waitpid. Handshake metadata
    // and descriptor operations remain confined to the test thread.
    private final class DescendantHandshake: @unchecked Sendable {
        let ready: Int32
        let exits: Int32
        private var checkedReadiness = false
        private(set) var pid: pid_t?
        private(set) var readyAt: TimeInterval?
        private(set) var exited = false

        init(ready: Int32, exits: Int32) {
            self.ready = ready
            self.exits = exits
        }

        func wait(pid: pid_t, status: UnsafeMutablePointer<Int32>, options: Int32) -> pid_t {
            if !checkedReadiness {
                checkedReadiness = true
                observeReadiness(timeout: 3)
            }
            return Darwin.waitpid(pid, status, options)
        }

        func observeReadiness(timeout: TimeInterval) {
            pid = Self.readMessage(from: ready, timeout: timeout).flatMap(Int32.init)
            guard let helper = pid else { return }
            var event = kevent64_s()
            event.ident = UInt64(helper)
            event.filter = Int16(EVFILT_PROC)
            event.flags = UInt16(EV_ADD | EV_ONESHOT)
            event.fflags = UInt32(NOTE_EXIT)
            if kevent64(exits, &event, 1, nil, 0, 0, nil) == 0 {
                readyAt = ProcessInfo.processInfo.systemUptime
            } else if errno == ESRCH {
                exited = true
            }
        }

        func waitForExit(timeout: TimeInterval) -> Bool {
            var event = kevent64_s()
            var bound = timespec(tv_sec: Int(timeout), tv_nsec: 0)
            exited = kevent64(exits, nil, 0, &event, 1, 0, &bound) == 1
                && event.ident == pid.map(UInt64.init) && event.fflags & UInt32(NOTE_EXIT) != 0
            return exited
        }

        static func readMessage(from descriptor: Int32, timeout: TimeInterval) -> String? {
            let deadline = ProcessInfo.processInfo.systemUptime + timeout
            var bytes = [UInt8]()
            while bytes.count < 64 {
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else { return nil }
                var event = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                let polled = poll(&event, 1, Int32(remaining * 1_000))
                if polled < 0 && errno == EINTR { continue }
                guard polled == 1 else { return nil }
                var byte: UInt8 = 0
                let count = read(descriptor, &byte, 1)
                if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                guard count == 1 else { return nil }
                if byte == 10 { return String(decoding: bytes, as: UTF8.self) }
                bytes.append(byte)
            }
            return nil
        }
    }

    // Model an OS that has not yet made an exited child waitable. Only the eventual
    // blocking reaper invokes real waitpid, so ownership and the capacity gate are deterministic.
    private final class DelayedReap: @unchecked Sendable {
        let entered = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        // Published to the test through the corresponding semaphores.
        private(set) var pid: pid_t = 0
        private(set) var result: pid_t = 0

        func wait(pid: pid_t, status: UnsafeMutablePointer<Int32>, options: Int32) -> pid_t {
            if options == WNOHANG { return 0 }
            self.pid = pid
            entered.signal()
            _ = resume.wait(timeout: .now() + 5)
            result = Darwin.waitpid(pid, status, options)
            finished.signal()
            return result
        }
    }

    private func assertFailure(_ result: RegistrationCommand.Result, _ expected: RegistrationCommand.Failure,
                               file: StaticString = #filePath, line: UInt = #line) {
        guard case let .failure(actual) = result else {
            return XCTFail("Expected failure \(expected)", file: file, line: line)
        }
        XCTAssertEqual(actual, expected, file: file, line: line)
    }

    private func snapshot(identifiers: [String] = ["test.extension"], known: Bool = true,
                          registration: ExtensionRegistration = .registered,
                          enabled: Bool = false, responded: Bool? = nil) -> FinderExtensionDiagnosticSnapshot {
        FinderExtensionDiagnosticSnapshot(embeddedIdentifiers: identifiers, embeddingKnown: known,
            registration: registration, registrationEvidence: "test", enabled: enabled, responded: responded)
    }
}
