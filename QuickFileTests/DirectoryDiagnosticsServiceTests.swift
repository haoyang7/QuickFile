import XCTest
import Darwin
@testable import QuickFileInfrastructure

final class DirectoryDiagnosticsServiceTests: XCTestCase {
    private var temporaryDirectory: URL!
    private let service = DirectoryDiagnosticsService()

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickFileDiagnosticsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
    }

    func testWritableDirectoryPassesWriteProbeAndCleansUp() throws {
        let report = service.inspect(folderURL: temporaryDirectory, performWriteProbe: true)

        XCTAssertTrue(report.exists)
        XCTAssertTrue(report.isDirectory)
        XCTAssertTrue(report.isWritableByFileManager)
        XCTAssertEqual(report.writeProbeSucceeded, true)
        XCTAssertNil(report.writeProbeErrorDescription)
        XCTAssertTrue(report.issues.isEmpty)

        let remainingNames = try FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path)
        XCTAssertFalse(remainingNames.contains { $0.hasPrefix(".quickfile-write-probe-") })
    }

    func testFilePathIsReportedAsNotDirectory() throws {
        let fileURL = temporaryDirectory.appendingPathComponent("file.txt")
        try Data().write(to: fileURL)

        let report = service.inspect(folderURL: fileURL, performWriteProbe: true)

        XCTAssertTrue(report.exists)
        XCTAssertFalse(report.isDirectory)
        XCTAssertNil(report.writeProbeSucceeded)
        XCTAssertTrue(report.issues.contains("目标路径不是文件夹。"))
    }

    func testMissingPathIsReported() {
        let missingURL = temporaryDirectory.appendingPathComponent("missing", isDirectory: true)

        let report = service.inspect(folderURL: missingURL, performWriteProbe: true)

        XCTAssertFalse(report.exists)
        XCTAssertFalse(report.isDirectory)
        XCTAssertTrue(report.issues.contains("目标路径不存在。"))
    }

    func testRecognizesTypicalICloudDrivePath() {
        let url = URL(fileURLWithPath: "/Users/example/Library/Mobile Documents/com~apple~CloudDocs/Documents")

        XCTAssertTrue(service.isLikelyICloudURL(url, resourceFlag: false))
        XCTAssertTrue(service.isLikelyICloudURL(URL(fileURLWithPath: "/tmp"), resourceFlag: true))
        XCTAssertFalse(service.isLikelyICloudURL(URL(fileURLWithPath: "/tmp"), resourceFlag: false))
    }

    func testProbeCleanupFollowsOpenedDirectoryWhenOriginalPathIsReused() throws {
        let folder = temporaryDirectory.appendingPathComponent("target")
        let moved = temporaryDirectory.appendingPathComponent("moved")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let service = DirectoryDiagnosticsService(beforeProbeCleanup: { probe in
            try FileManager.default.moveItem(at: folder, to: moved)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            try "user data".write(to: folder.appendingPathComponent(probe.lastPathComponent), atomically: false, encoding: .utf8)
        })

        let report = service.inspect(folderURL: folder)

        XCTAssertEqual(report.writeProbeSucceeded, true)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: moved.path), [])
        let sentinel = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first)
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "user data")
    }

    func testReplacedProbeDirectoryIsPreservedForFileNonemptyAndEmptyDirectory() throws {
        for replacement in ["file", "nonempty", "empty"] {
            let folder = temporaryDirectory.appendingPathComponent(replacement)
            let moved = folder.appendingPathComponent("moved-probe")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            let service = DirectoryDiagnosticsService(beforeProbeCleanup: { probe in
                try FileManager.default.moveItem(at: probe, to: moved)
                if replacement == "file" {
                    try "user data".write(to: probe, atomically: false, encoding: .utf8)
                } else {
                    try FileManager.default.createDirectory(at: probe, withIntermediateDirectories: false)
                    if replacement == "nonempty" {
                        try "user data".write(to: probe.appendingPathComponent("payload"), atomically: false, encoding: .utf8)
                    }
                }
            })

            let report = service.inspect(folderURL: folder)

            XCTAssertEqual(report.writeProbeSucceeded, false, replacement)
            XCTAssertTrue(report.writeProbeErrorDescription?.contains("残留") == true)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: moved.path), [])
            let replacementURL = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .first { $0.lastPathComponent.hasPrefix(".quickfile-write-probe-") })
            if replacement == "file" {
                XCTAssertEqual(try String(contentsOf: replacementURL, encoding: .utf8), "user data")
            } else if replacement == "nonempty" {
                XCTAssertEqual(try String(contentsOf: replacementURL.appendingPathComponent("payload"), encoding: .utf8), "user data")
            } else {
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: replacementURL.path), [])
            }
        }
    }

    func testFailedExclusiveProbeCreationDoesNotDeleteExistingEntry() throws {
        let service = DirectoryDiagnosticsService(beforeProbeWrite: { probe in
            try "user data".write(to: probe.appendingPathComponent("payload"), atomically: false, encoding: .utf8)
        })

        let report = service.inspect(folderURL: temporaryDirectory)

        XCTAssertEqual(report.writeProbeSucceeded, false)
        let probe = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: temporaryDirectory, includingPropertiesForKeys: nil).first)
        XCTAssertEqual(try String(contentsOf: probe.appendingPathComponent("payload"), encoding: .utf8), "user data")
        XCTAssertTrue(report.writeProbeErrorDescription?.contains(probe.lastPathComponent) == true)
    }

    func testCleanupReportsResidualWithoutRecursivelyDeletingUnexpectedContents() throws {
        let service = DirectoryDiagnosticsService(beforeProbeCleanup: { probe in
            try "user data".write(to: probe.appendingPathComponent("keep.txt"), atomically: false, encoding: .utf8)
        })

        let report = service.inspect(folderURL: temporaryDirectory)

        XCTAssertEqual(report.writeProbeSucceeded, false)
        let probe = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: temporaryDirectory, includingPropertiesForKeys: nil).first)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: probe.path), ["keep.txt"])
        XCTAssertEqual(try String(contentsOf: probe.appendingPathComponent("keep.txt"), encoding: .utf8), "user data")
        XCTAssertTrue(report.writeProbeErrorDescription?.contains(probe.lastPathComponent) == true)
    }

    func testWriteProbeDoesNotRequireDirectoryListingPermission() throws {
        XCTAssertEqual(chmod(temporaryDirectory.path, 0o300), 0)
        defer { chmod(temporaryDirectory.path, 0o700) }

        let report = service.inspect(folderURL: temporaryDirectory)

        XCTAssertEqual(report.writeProbeSucceeded, true, report.writeProbeErrorDescription ?? "")
    }

    func testSharedNonstickyDirectoryRejectsProbeBeforeCreatingAnyEntry() throws {
        XCTAssertEqual(chmod(temporaryDirectory.path, 0o777), 0)
        let service = DirectoryDiagnosticsService(beforeProbeWrite: { _ in
            XCTFail("Unsafe shared namespace must be rejected before creating a probe")
        })

        let report = service.inspect(folderURL: temporaryDirectory)

        XCTAssertEqual(report.writeProbeSucceeded, false)
        XCTAssertTrue(report.writeProbeErrorDescription?.contains("其他用户替换") == true)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path), [])
    }

    func testOwnedStickySharedDirectoryProtectsProbeEntries() throws {
        XCTAssertEqual(chmod(temporaryDirectory.path, 0o1777), 0)

        let report = service.inspect(folderURL: temporaryDirectory)

        XCTAssertEqual(report.writeProbeSucceeded, true, report.writeProbeErrorDescription ?? "")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path), [])
    }

    func testNamespaceMutationACLRejectsProbeDespiteOwnerOnlyMode() throws {
        for permission in ["delete_child", "writesecurity", "chown"] {
            let folder = temporaryDirectory.appendingPathComponent(permission)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let acl = try XCTUnwrap(acl_from_text("!#acl 1\ngroup:ABCDEFAB-CDEF-ABCD-EFAB-CDEF0000000C:everyone:12:allow:\(permission)\n"))
            defer { acl_free(UnsafeMutableRawPointer(acl)) }
            XCTAssertEqual(acl_set_file(folder.path, ACL_TYPE_EXTENDED, acl), 0)

            let report = service.inspect(folderURL: folder)

            XCTAssertEqual(report.writeProbeSucceeded, false, permission)
            XCTAssertTrue(report.writeProbeErrorDescription?.contains("其他用户替换") == true)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
        }
    }

    func testInheritOnlyDirectoryAccessIsRejectedBeforeProbeCanBeReplaced() throws {
        XCTAssertEqual(chmod(temporaryDirectory.path, 0o700), 0)
        let acl = try XCTUnwrap(acl_from_text("!#acl 1\ngroup:ABCDEFAB-CDEF-ABCD-EFAB-CDEF0000000C:everyone:12:allow,directory_inherit,only_inherit:delete\n"))
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        XCTAssertEqual(acl_set_file(temporaryDirectory.path, ACL_TYPE_EXTENDED, acl), 0)
        let service = DirectoryDiagnosticsService(beforeProbeWrite: { _ in
            XCTFail("Inherited directory grants must be rejected before creating the probe")
        })

        let report = service.inspect(folderURL: temporaryDirectory)

        XCTAssertEqual(report.writeProbeSucceeded, false)
        XCTAssertTrue(report.writeProbeErrorDescription?.contains("其他用户替换") == true)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path), [])
    }

    func testUnsearchableAncestorReportsUnknownExistenceAndRecoversAfterRestoringAccess() throws {
        let parent = temporaryDirectory.appendingPathComponent("no-search")
        let child = parent.appendingPathComponent("existing-child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(parent.path, 0o600), 0)
        defer { chmod(parent.path, 0o700) }

        let inaccessible = service.inspect(folderURL: child)

        XCTAssertFalse(inaccessible.existenceKnown)
        XCTAssertEqual(inaccessible.metadataErrorCode, EACCES)
        XCTAssertTrue(inaccessible.metadataErrorDescription?.contains("权限不足") == true)
        XCTAssertFalse(inaccessible.issues.contains("目标路径不存在。"))
        XCTAssertNil(inaccessible.writeProbeSucceeded)
        XCTAssertEqual(chmod(parent.path, 0o700), 0)

        let accessible = service.inspect(folderURL: child)

        XCTAssertTrue(accessible.existenceKnown)
        XCTAssertTrue(accessible.exists)
        XCTAssertTrue(accessible.isDirectory)
        XCTAssertNil(accessible.metadataErrorCode)
        XCTAssertNil(accessible.metadataErrorDescription)
        XCTAssertEqual(accessible.writeProbeSucceeded, true)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: child.path), [])
    }

    func testMetadataLookupDistinguishesMissingNonDirectoryAndUnknownErrors() throws {
        let file = temporaryDirectory.appendingPathComponent("file")
        try Data().write(to: file)
        let loop = temporaryDirectory.appendingPathComponent("loop")
        XCTAssertEqual(symlink("loop", loop.path), 0)
        for (destination, code) in [(temporaryDirectory.appendingPathComponent("missing"), ENOENT),
                                    (file.appendingPathComponent("child"), ENOTDIR), (loop, ELOOP)] {
            let report = service.inspect(folderURL: destination)

            XCTAssertEqual(report.metadataErrorCode, code)
            XCTAssertFalse(report.exists)
            XCTAssertFalse(report.isDirectory)
            XCTAssertNil(report.writeProbeSucceeded)
            if code == ELOOP {
                XCTAssertFalse(report.existenceKnown)
                XCTAssertTrue(report.metadataErrorDescription?.contains("无法确定") == true)
                XCTAssertFalse(report.issues.contains("目标路径不存在。"))
            } else {
                XCTAssertTrue(report.existenceKnown)
                XCTAssertNil(report.metadataErrorDescription)
                XCTAssertTrue(report.issues.contains("目标路径不存在。"))
            }
        }
    }
}
