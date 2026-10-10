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
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: marker) }
        let start = ProcessInfo.processInfo.systemUptime
        let result = RegistrationCommand.run(executable: "/bin/sh", arguments: ["-c",
            "(/bin/sleep 0.5; printf survived > '\(marker.path)') & exit 0"], timeout: 0.1)
        assertFailure(result, .timeout)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.4)
        // The helper descendants exit naturally and must survive the query cleanup.
        Thread.sleep(forTimeInterval: 0.55)
        XCTAssertEqual(try String(contentsOf: marker), "survived")
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
