import CryptoKit
import Foundation
import XCTest
@testable import QuickFile

final class CommunityReleaseCheckerTests: XCTestCase {
    func testStableChannelDoesNotTreatPublishedBetaAsStable() async throws {
        let fixture = Fixture(tag: "v0.1.0-beta.2", build: "98")
        try await assertResult(.noPublishedRelease, fixture: fixture, includingBetas: false)
        try await assertResult(.updateAvailable(fixture.release), fixture: fixture, build: "97")
    }

    func testBetaNumbersAndMarketingComponentsSortNumerically() async throws {
        var fixture = Fixture(tag: "v0.1.0-beta.10", build: "110")
        fixture.records += Fixture(tag: "v0.1.0-beta.2", build: "102").records
        try await assertResult(.updateAvailable(fixture.release), fixture: fixture)
        fixture = Fixture(tag: "v0.10.0", build: "1")
        fixture.records += Fixture(tag: "v0.9.0", build: "999").records
        try await assertResult(.updateAvailable(fixture.release), fixture: fixture, version: "0.9.0", build: "999")
    }

    func testStableWinsOverBetaWithSameMarketingVersion() async throws {
        var fixture = Fixture(tag: "v0.1.0", build: "100")
        fixture.records += Fixture(tag: "v0.1.0-beta.999", build: "999").records
        try await assertResult(.updateAvailable(fixture.release), fixture: fixture)
        try await assertResult(.updateAvailable(fixture.release), fixture: fixture, includingBetas: false)
    }

    func testDraftNeverBecomesCandidate() async throws {
        var fixture = Fixture(tag: "v0.1.0", build: "98")
        var draft = Fixture(tag: "v9.0.0", build: "999").records[0]
        draft["draft"] = true
        fixture.records.append(draft)
        try await assertResult(.updateAvailable(fixture.release), fixture: fixture)
        fixture.records = [draft]
        try await assertResult(.noPublishedRelease, fixture: fixture)
    }

    func testSameMarketingVersionUsesPublishedInternalBuild() async throws {
        let fixture = Fixture(tag: "v0.1.0-beta.2", build: "98")
        try await assertResult(.updateAvailable(fixture.release), fixture: fixture, build: "97")
        try await assertResult(.upToDate, fixture: fixture, build: "98")
        try await assertResult(.upToDate, fixture: fixture, build: "99")
    }

    func testMarketingVersionTakesPrecedenceOverBuild() async throws {
        let fixture = Fixture(tag: "v0.2.0", build: "1")
        try await assertResult(.updateAvailable(fixture.release), fixture: fixture, build: "999")
        try await assertResult(.upToDate, fixture: fixture, version: "0.3.0", build: "1")
    }

    func testInstalledBetaOrdinalTakesPrecedenceOverBuild() async throws {
        let newer = Fixture(tag: "v0.1.0-beta.10", build: "1")
        try await assertResult(.updateAvailable(newer.release), fixture: newer, build: "999",
                               releaseTag: "v0.1.0-beta.2")
        let older = Fixture(tag: "v0.1.0-beta.2", build: "999")
        try await assertResult(.upToDate, fixture: older, build: "1", releaseTag: "v0.1.0-beta.10")
    }

    func testInstalledBetaCanUpgradeToStableWithoutHigherBuild() async throws {
        for build in ["1", "999"] {
            let fixture = Fixture(tag: "v0.1.0", build: build)
            for includingBetas in [false, true] {
                try await assertResult(.updateAvailable(fixture.release), fixture: fixture, build: "999",
                                       releaseTag: "v0.1.0-beta.10", includingBetas: includingBetas)
            }
        }
    }

    func testInstalledStableNeverDowngradesToSameVersionBeta() async throws {
        let fixture = Fixture(tag: "v0.1.0-beta.999", build: "999")
        try await assertResult(.upToDate, fixture: fixture, build: "1", releaseTag: "v0.1.0")
        try await assertResult(.noPublishedRelease, fixture: fixture, build: "1",
                               releaseTag: "v0.1.0", includingBetas: false)
    }

    func testNewMarketingVersionBetaRemainsEligibleWhenEnabled() async throws {
        let fixture = Fixture(tag: "v0.2.0-beta.1", build: "1")
        try await assertResult(.updateAvailable(fixture.release), fixture: fixture, build: "999",
                               releaseTag: "v0.1.0")
        try await assertResult(.noPublishedRelease, fixture: fixture, releaseTag: "v0.1.0", includingBetas: false)
    }

    func testIdenticalInstalledReleaseTagsUseBuildToCompareRebuilds() async throws {
        for tag in ["v0.1.0", "v0.1.0-beta.2"] {
            let fixture = Fixture(tag: tag, build: "98")
            try await assertResult(.updateAvailable(fixture.release), fixture: fixture, build: "97", releaseTag: tag)
            try await assertResult(.upToDate, fixture: fixture, build: "98", releaseTag: tag)
            try await assertResult(.upToDate, fixture: fixture, build: "99", releaseTag: tag)
        }
    }

    func testInvalidOrMismatchedInstalledTagFailsBeforeNetwork() async throws {
        let checker = CommunityReleaseChecker { request, _ in
            XCTFail("Invalid installed metadata must not issue a request")
            return .init(data: Data("[]".utf8), statusCode: 200, url: request.url!)
        }
        for tag in ["", "0.1.0", "v0.2.0", "v0.2.0-beta.1", "v0.1.0-beta.0", "v0.1.0-beta.01",
                    "v0.1.0-beta.１", "v0.1.0-beta.9999999999999999999", "v0.1.0-rc.1", " v0.1.0"] {
            try await assertError(.invalidCurrentVersion, checker: checker, releaseTag: tag)
        }
    }

    func testInstalledVersionNameShowsOnlyValidMatchingBetaTag() {
        XCTAssertEqual(CommunityReleaseChecker.installedVersionName(version: "0.1.0", releaseTag: "v0.1.0-beta.2"),
                       "0.1.0 Beta 2")
        XCTAssertEqual(CommunityReleaseChecker.installedVersionName(version: "0.1.0", releaseTag: "v0.1.0-beta.10"),
                       "0.1.0 Beta 10")
        for tag in [nil, "v0.1.0", "v0.2.0-beta.2", "v0.1.0-beta.0", "v0.1.0-beta.01",
                    "v0.1.0-beta.２", "v0.1.0-beta.9999999999999999999", ""] as [String?] {
            XCTAssertEqual(CommunityReleaseChecker.installedVersionName(version: "0.1.0", releaseTag: tag), "0.1.0")
        }
        XCTAssertEqual(CommunityReleaseChecker.installedVersionName(version: "Unknown", releaseTag: nil), "Unknown")
    }

    func testMalformedTagsAndPrereleaseFlagDisagreementsAreExcluded() async throws {
        for tag in ["0.1.0", "v0.1", "v0.1.0.0", "v0.1.0-rc.1", "v0.1.0-beta.0", "v0.1.0-beta.-1",
                    "v0.1.0-beta.01", "v0.1.0-beta.１", "v0.1.0-beta.2+build", "v0.01.0", "v0.1.0/evil"] {
            try await assertResult(.noPublishedRelease, fixture: Fixture(tag: tag, build: "98"))
        }
        var stable = Fixture(tag: "v0.1.0", build: "98")
        stable.records[0]["prerelease"] = true
        try await assertResult(.noPublishedRelease, fixture: stable)
        var beta = Fixture(tag: "v0.1.0-beta.2", build: "98")
        beta.records[0]["prerelease"] = false
        try await assertResult(.noPublishedRelease, fixture: beta)
    }

    func testCurrentVersionAndBuildRequireBoundedASCIINumbers() async throws {
        let fixture = Fixture(tag: "v0.1.0", build: "98")
        for version in ["", "v0.1.0", "0.1", "0.1.0-beta.2", "0.１.0", "0.-1.0", "0.1.9999999999999999999"] {
            try await assertError(.invalidCurrentVersion, checker: fixture.checker(), version: version)
        }
        for build in ["", "0", "-1", "９８", "98.0", "9999999999999999999"] {
            try await assertError(.invalidCurrentVersion, checker: fixture.checker(), build: build)
        }
    }

    func testEmptyListHasNoPublishedReleaseAndInvalidJSONFails() async throws {
        var fixture = Fixture(tag: "v0.1.0", build: "98")
        fixture.records = []
        try await assertResult(.noPublishedRelease, fixture: fixture)
        let checker = CommunityReleaseChecker { request, _ in
            .init(data: Data("{broken".utf8), statusCode: 200, url: request.url!)
        }
        try await assertError(.invalidResponse, checker: checker)
    }

    func testMissingDuplicateAndUnfinishedAssetsFailExplicitly() async throws {
        for name in ["QuickFile-v0.1.0.dmg", "QuickFile-v0.1.0.dmg.sha256", "build-provenance.json"] {
            let original = Fixture(tag: "v0.1.0", build: "98")
            let assets = original.records[0]["assets"] as! [[String: Any]]
            var fixture = original
            fixture.records[0]["assets"] = assets.filter { $0["name"] as? String != name }
            try await assertError(.missingProvenance, checker: fixture.checker())
            fixture = original
            fixture.records[0]["assets"] = assets + assets.filter { $0["name"] as? String == name }
            try await assertError(.missingProvenance, checker: fixture.checker())
            fixture = original
            fixture.records[0]["assets"] = assets.map { asset in
                var asset = asset
                if asset["name"] as? String == name { asset["state"] = "new" }
                return asset
            }
            try await assertError(.missingProvenance, checker: fixture.checker())
        }
    }

    func testReceiptMustMatchTagSchemaTrustAndBoundedInternalBuild() async throws {
        for (key, value) in [("release_tag", "v0.1.0-beta.2" as Any), ("schema_version", 2),
                             ("trust", "developer-id"), ("internal_build", "９８"),
                             ("internal_build", "9999999999999999999"), ("internal_build", 98)] {
            var fixture = Fixture(tag: "v0.1.0", build: "98")
            fixture.provenance[key] = value
            try await assertError(.missingProvenance, checker: fixture.checker())
        }
        var fixture = Fixture(tag: "v0.1.0", build: "98")
        fixture.provenance.removeValue(forKey: "internal_build")
        try await assertError(.missingProvenance, checker: fixture.checker())
    }

    func testReceiptAssetNameBytesAndHashesMustAgreeWithAPI() async throws {
        for (key, value) in [("name", "other.dmg" as Any), ("bytes", 11), ("sha256", "invalid"),
                             ("sha256", String(repeating: "b", count: 64))] {
            var fixture = Fixture(tag: "v0.1.0", build: "98")
            var assets = fixture.provenance["assets"] as! [[String: Any]]
            assets[0][key] = value
            fixture.provenance["assets"] = assets
            try await assertError(.missingProvenance, checker: fixture.checker())
        }
        var fixture = Fixture(tag: "v0.1.0", build: "98")
        var assets = fixture.provenance["assets"] as! [[String: Any]]
        assets.append(assets[0])
        fixture.provenance["assets"] = assets
        try await assertError(.missingProvenance, checker: fixture.checker())
    }

    func testAPIWithoutOptionalDigestStillChecksReceiptMetadata() async throws {
        var fixture = Fixture(tag: "v0.1.0", build: "98")
        fixture.records[0]["assets"] = (fixture.records[0]["assets"] as! [[String: Any]]).map { asset in
            var asset = asset
            asset.removeValue(forKey: "digest")
            return asset
        }
        try await assertResult(.updateAvailable(fixture.release), fixture: fixture)
    }

    func testReceiptResponseSizeAndDigestAreChecked() async throws {
        var fixture = Fixture(tag: "v0.1.0", build: "98")
        fixture.receiptMetadataOverride = (1, nil)
        try await assertError(.missingProvenance, checker: fixture.checker())
        fixture.receiptMetadataOverride = (nil, "sha256:" + String(repeating: "b", count: 64))
        try await assertError(.missingProvenance, checker: fixture.checker())
    }

    func testMissingReceiptResponseIsNotReportedAsUpToDate() async throws {
        var fixture = Fixture(tag: "v0.1.0", build: "98")
        fixture.receiptStatus = 404
        try await assertError(.missingProvenance, checker: fixture.checker(), build: "999")
    }

    func testHighestCandidateCannotSilentlyFallBackToOlderRelease() async throws {
        var fixture = Fixture(tag: "v0.2.0", build: "100")
        fixture.records[0]["assets"] = []
        fixture.records += Fixture(tag: "v0.1.0", build: "98").records
        try await assertError(.missingProvenance, checker: fixture.checker())
    }

    func testDuplicateSelectedReleaseIsRejected() async throws {
        var fixture = Fixture(tag: "v0.1.0", build: "98")
        fixture.records += fixture.records
        try await assertError(.invalidResponse, checker: fixture.checker())
    }

    func testHTTPFailuresAndRateLimits() async throws {
        for status in [403, 429, 404, 500, 204] {
            var fixture = Fixture(tag: "v0.1.0", build: "98")
            fixture.listStatus = status
            try await assertError([403, 429].contains(status) ? .rateLimited : .requestFailed, checker: fixture.checker())
            fixture.listStatus = 200
            fixture.receiptStatus = status
            try await assertError([403, 429].contains(status) ? .rateLimited : status == 404 ? .missingProvenance : .requestFailed,
                                  checker: fixture.checker())
        }
        let checker = CommunityReleaseChecker { _, _ in throw URLError(.timedOut) }
        try await assertError(.requestFailed, checker: checker)
    }

    func testListAndReceiptResponsesHaveIndependentByteLimits() async throws {
        let list = CommunityReleaseChecker { request, limit in
            XCTAssertEqual(limit, 1_048_576)
            return .init(data: Data(repeating: 32, count: limit + 1), statusCode: 200, url: request.url!)
        }
        try await assertError(.responseTooLarge, checker: list)
        var fixture = Fixture(tag: "v0.1.0", build: "98")
        fixture.receiptDataOverride = Data(repeating: 32, count: 65_537)
        try await assertError(.responseTooLarge, checker: fixture.checker())
    }

    func testPaginationIncludesLaterCandidatesAndStopsAtThreePages() async throws {
        let fixture = Fixture(tag: "v0.1.0", build: "98")
        let checker = try fixture.checker(emptyFirstPages: 2)
        let result = try await checker.check(version: "0.1.0", build: "97", includingBetas: true)
        XCTAssertEqual(result, .updateAvailable(fixture.release))
        try await assertError(.responseTooLarge, checker: fixture.checker(emptyFirstPages: 3))
    }

    func testPaginationAcceptsNamedAndNumericRepositoryPathsWithEquivalentQueries() async throws {
        for path in ["repos/haoyang7/QuickFile", "repositories/1412789324"] {
            for query in ["per_page=100&page=2", "page=2&per_page=100"] {
                let nextPage = expectation(description: "Fetch the next page for \(path)?\(query)")
                let checker = CommunityReleaseChecker { request, _ in
                    let url = try XCTUnwrap(request.url)
                    let isFirstPage = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                        .contains(where: { $0.name == "page" }) == false
                    if isFirstPage {
                        return .init(data: Data("[]".utf8), statusCode: 200, url: url,
                                     headers: ["Link": "<https://api.github.com/\(path)/releases?\(query)>; rel=\"next\""])
                    }
                    // Link URLs control pagination; requests retain the fixed named repository endpoint.
                    XCTAssertEqual(url.absoluteString, "https://api.github.com/repos/haoyang7/QuickFile/releases?per_page=100&page=2")
                    nextPage.fulfill()
                    return .init(data: Data("[]".utf8), statusCode: 200, url: url)
                }
                let result = try await checker.check(version: "0.1.0", build: "105", includingBetas: true)
                XCTAssertEqual(result, .noPublishedRelease)
                await fulfillment(of: [nextPage], timeout: 2)
            }
        }
    }

    func testPaginationRejectsChangedRepositoryAndUnexpectedPageParameters() async throws {
        let endpoint = "https://api.github.com/repositories/1412789324/releases"
        let urls = [
            "https://example.org/repositories/1412789324/releases?per_page=100&page=2",
            "http://api.github.com/repositories/1412789324/releases?per_page=100&page=2",
            "https://user@api.github.com/repositories/1412789324/releases?per_page=100&page=2",
            "https://api.github.com:444/repositories/1412789324/releases?per_page=100&page=2",
            "https://api.github.com/repos/other/QuickFile/releases?per_page=100&page=2",
            "https://api.github.com/repositories/274782/releases?per_page=100&page=2",
            "https://api.github.com/repositories/1412789324/issues?per_page=100&page=2",
            "\(endpoint)?per_page=100&page=2#fragment",
            "\(endpoint)?per_page=100&page=1",
            "\(endpoint)?per_page=100&page=3",
            "\(endpoint)?per_page=1&page=2",
            "\(endpoint)?per_page=100&page=2&page=2",
            "\(endpoint)?per_page=100&per_page=100&page=2",
            "\(endpoint)?per_page=100&page=2&unexpected=1",
            endpoint
        ]
        for url in urls {
            let checker = CommunityReleaseChecker { request, _ in
                .init(data: Data("[]".utf8), statusCode: 200, url: try XCTUnwrap(request.url),
                      headers: ["Link": "<\(url)>; rel=\"next\""])
            }
            try await assertError(.invalidResponse, checker: checker)
        }
        let repeatedNext = "<\(endpoint)?per_page=100&page=2>; rel=\"next\""
        let checker = CommunityReleaseChecker { request, _ in
            .init(data: Data("[]".utf8), statusCode: 200, url: try XCTUnwrap(request.url),
                  headers: ["Link": "\(repeatedNext), \(repeatedNext)"])
        }
        try await assertError(.invalidResponse, checker: checker)
    }

    func testInvalidPaginationURLAndTooManyRecordsFail() async throws {
        let checker = CommunityReleaseChecker { request, _ in
            .init(data: Data("[]".utf8), statusCode: 200, url: request.url!,
                  headers: ["Link": "<https://example.org/releases?page=2>; rel=\"next\""])
        }
        try await assertError(.invalidResponse, checker: checker)
        var fixture = Fixture(tag: "v0.1.0", build: "98")
        fixture.records = Array(repeating: fixture.records[0], count: 101)
        try await assertError(.invalidResponse, checker: fixture.checker())
    }

    func testMalformedPaginationDoesNotSilentlyTruncateResults() async throws {
        for link in ["", "not-a-link", "<https://example.org/page>", "<https://example.org/page>; rel=\"next\" rel=\"last\""] {
            let checker = CommunityReleaseChecker { request, _ in
                .init(data: Data("[]".utf8), statusCode: 200, url: request.url!, headers: ["Link": link])
            }
            try await assertError(.invalidResponse, checker: checker)
        }
    }

    func testListFinalURLCannotChangeDataSource() async throws {
        for url in ["https://github.com/haoyang7/QuickFile/releases", "https://api.github.com/repos/other/QuickFile/releases?per_page=100",
                    "http://api.github.com/repos/haoyang7/QuickFile/releases?per_page=100",
                    "https://user@api.github.com/repos/haoyang7/QuickFile/releases?per_page=100"] {
            var fixture = Fixture(tag: "v0.1.0", build: "98")
            fixture.listFinalURL = URL(string: url)!
            try await assertError(.invalidResponse, checker: fixture.checker())
        }
    }

    func testReceiptFinalURLHasRestrictedHTTPSHostsAndPorts() async throws {
        for url in ["http://github.com/file", "https://github.com.evil.example/file", "https://evil.example/file",
                    "https://user:password@github.com/file", "https://github.com:444/file", "https://github.com/file#fragment"] {
            var fixture = Fixture(tag: "v0.1.0", build: "98")
            fixture.receiptFinalURL = URL(string: url)!
            try await assertError(.invalidResponse, checker: fixture.checker())
        }
        for host in ["github.com", "api.github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com"] {
            var fixture = Fixture(tag: "v0.1.0", build: "98")
            fixture.receiptFinalURL = URL(string: "https://\(host):443/file?signature=example")!
            try await assertResult(.updateAvailable(fixture.release), fixture: fixture)
        }
    }

    func testAssetURLMustBelongToFixedRepositoryAndSelectedTag() async throws {
        for url in ["https://example.org/build-provenance.json",
                    "https://github.com/other/QuickFile/releases/download/v0.1.0/build-provenance.json",
                    "https://github.com/haoyang7/QuickFile/releases/download/v0.0.1/build-provenance.json"] {
            var fixture = Fixture(tag: "v0.1.0", build: "98")
            var assets = fixture.records[0]["assets"] as! [[String: Any]]
            assets[2]["browser_download_url"] = url
            fixture.records[0]["assets"] = assets
            try await assertError(.missingProvenance, checker: fixture.checker())
        }
    }

    func testForgedHTMLPageIsIgnoredAndOnlyReceiptIsDownloaded() async throws {
        var fixture = Fixture(tag: "v0.1.0", build: "98")
        fixture.records[0]["html_url"] = "https://example.org/forged"
        try await assertResult(.updateAvailable(fixture.release), fixture: fixture)
    }

    func testRequestsDisableCookiesAndUseGitHubJSONHeaders() async throws {
        let checker = CommunityReleaseChecker { request, _ in
            XCTAssertFalse(request.httpShouldHandleCookies)
            XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
            XCTAssertEqual(request.timeoutInterval, 20)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2026-03-10")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return .init(data: Data("[]".utf8), statusCode: 200, url: request.url!)
        }
        let result = try await checker.check(version: "0.1.0", build: "99", includingBetas: true)
        XCTAssertEqual(result, .noPublishedRelease)
    }

    func testCancellationPropagatesWithoutRetryOrConversion() async throws {
        let checker = CommunityReleaseChecker { _, _ in throw CancellationError() }
        do {
            _ = try await checker.check(version: "0.1.0", build: "99", includingBetas: true)
            XCTFail("Expected cancellation")
        } catch is CancellationError { }
        catch { XCTFail("Unexpected error: \(error)") }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await CommunityReleaseChecker { _, _ in
                XCTFail("Cancelled checks must not start a request")
                throw CancellationError()
            }.check(version: "0.1.0", build: "99", includingBetas: true)
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
    }

    func testProductionByteStreamStopsAtLimitWithoutContentLength() async throws {
        for chunked in [false, true] {
            let scenario = TransportScenario(mode: .overflow(chunked: chunked))
            let request = scenario.request()
            do {
                _ = try await CommunityReleaseChecker.fetchResponse(request, limit: 1_024,
                                                                    protocolClasses: [TransportProtocol.self],
                                                                    sessionObserver: { scenario.observe($0) })
                XCTFail("Expected the streamed byte limit")
            } catch { XCTAssertEqual(error as? CommunityReleaseCheckError, .responseTooLarge) }
            await fulfillment(of: [scenario.stopped, scenario.released], timeout: 3)
            XCTAssertLessThan(scenario.snapshot().chunks, 100)
            XCTAssertEqual(scenario.snapshot().urls.count, 1)
            XCTAssertTrue(scenario.snapshot().taskWasObserved)
            try await assertReleasedTransport(scenario)
        }
    }

    func testProductionTransportCancellationWhileWaitingForResponseAndBody() async throws {
        for mode in [TransportScenario.Mode.waitForResponse, .waitForBody] {
            let scenario = TransportScenario(mode: mode)
            let finished = expectation(description: "Cancelled transport finished")
            let request = scenario.request()
            let task = Task {
                defer { finished.fulfill() }
                return try await CommunityReleaseChecker.fetchResponse(request, limit: 1_024,
                                                                       protocolClasses: [TransportProtocol.self],
                                                                       sessionObserver: { scenario.observe($0) })
            }
            await fulfillment(of: [scenario.ready], timeout: 3)
            task.cancel()
            await fulfillment(of: [finished, scenario.stopped, scenario.released], timeout: 3)
            do { _ = try await task.value; XCTFail("Expected cancellation") }
            catch {
                XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled)
            }
            XCTAssertEqual(scenario.snapshot().urls.count, 1)
            XCTAssertTrue(scenario.snapshot().taskWasObserved)
            try await assertReleasedTransport(scenario)
        }
    }

    func testProductionTransportFollowsOnlyAllowedReleaseAssetRedirects() async throws {
        let target = URL(string: "https://release-assets.githubusercontent.com/example/receipt")!
        let scenario = TransportScenario(mode: .redirect(target))
        scenario.released.expectedFulfillmentCount = 2
        let response = try await CommunityReleaseChecker.fetchResponse(scenario.request(), limit: 1_024,
                                                                       protocolClasses: [TransportProtocol.self],
                                                                       sessionObserver: { scenario.observe($0) })
        XCTAssertEqual(response.url, target)
        XCTAssertEqual(response.data, Data("[]".utf8))
        await fulfillment(of: [scenario.stopped, scenario.released], timeout: 3)
        XCTAssertEqual(scenario.snapshot().urls, [TransportScenario.origin, target])
        try await assertReleasedTransport(scenario)
    }

    func testProductionTransportRejectsUnsafeRedirectsBeforeFollowing() async throws {
        for target in ["http://github.com/receipt", "https://example.org/receipt", "https://github.com:444/receipt",
                       "https://user:password@github.com/receipt"] {
            let scenario = TransportScenario(mode: .redirect(URL(string: target)!))
            do {
                _ = try await CommunityReleaseChecker.fetchResponse(scenario.request(), limit: 1_024,
                                                                    protocolClasses: [TransportProtocol.self],
                                                                    sessionObserver: { scenario.observe($0) })
                XCTFail("Unsafe redirect must fail")
            } catch {
                // A declined URLProtocol redirect has no original response body; Foundation may return URLError.
                XCTAssertTrue(error is URLError || error as? CommunityReleaseCheckError == .requestFailed)
            }
            await fulfillment(of: [scenario.stopped, scenario.released], timeout: 3)
            XCTAssertEqual(scenario.snapshot().urls, [TransportScenario.origin])
            try await assertReleasedTransport(scenario)
        }
    }

    func testProductionTransportDoesNotRedirectReleaseListToAnotherSource() async throws {
        let origin = URL(string: "https://api.github.com/repos/haoyang7/QuickFile/releases?per_page=100")!
        let scenario = TransportScenario(mode: .redirect(TransportScenario.origin), initialURL: origin)
        do {
            _ = try await CommunityReleaseChecker.fetchResponse(scenario.request(), limit: 1_024,
                                                                protocolClasses: [TransportProtocol.self],
                                                                sessionObserver: { scenario.observe($0) })
            XCTFail("The list must stay on its original API URL")
        } catch {
            XCTAssertTrue(error is URLError || error as? CommunityReleaseCheckError == .requestFailed)
        }
        await fulfillment(of: [scenario.stopped, scenario.released], timeout: 3)
        XCTAssertEqual(scenario.snapshot().urls, [origin])
        try await assertReleasedTransport(scenario)
    }

    private func assertReleasedTransport(_ scenario: TransportScenario, file: StaticString = #filePath, line: UInt = #line) async throws {
        XCTAssertTrue(scenario.snapshot().taskWasObserved, file: file, line: line)
        XCTAssertTrue(scenario.snapshot().sessionWasObserved, file: file, line: line)
        for _ in 0..<300 {
            let state = scenario.snapshot()
            if state.taskReleased && state.sessionReleased { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("The completed URLSession or task is still retained", file: file, line: line)
    }

    private func assertResult(_ expected: CommunityReleaseCheckResult, fixture: Fixture, version: String = "0.1.0",
                              build: String = "97", releaseTag: String? = nil, includingBetas: Bool = true,
                              file: StaticString = #filePath, line: UInt = #line) async throws {
        let actual = try await fixture.checker().check(version: version, build: build, releaseTag: releaseTag,
                                                     includingBetas: includingBetas)
        XCTAssertEqual(actual, expected, file: file, line: line)
    }

    private func assertError(_ expected: CommunityReleaseCheckError, checker: CommunityReleaseChecker,
                             version: String = "0.1.0", build: String = "97", releaseTag: String? = nil,
                             file: StaticString = #filePath, line: UInt = #line) async throws {
        do {
            _ = try await checker.check(version: version, build: build, releaseTag: releaseTag, includingBetas: true)
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch { XCTAssertEqual(error as? CommunityReleaseCheckError, expected, file: file, line: line) }
    }

    private struct Fixture {
        let release: CommunityRelease
        var records: [[String: Any]]
        var provenance: [String: Any]
        var listStatus = 200
        var receiptStatus = 200
        var listFinalURL: URL?
        var receiptFinalURL: URL?
        var receiptDataOverride: Data?
        var receiptMetadataOverride: (size: Int?, digest: String?)?

        init(tag: String, build: String) {
            release = .init(tag: tag, version: String(tag.dropFirst().components(separatedBy: "-beta.")[0]),
                            build: build, pageURL: CommunityReleaseChecker.releasesPage.appendingPathComponent("tag").appendingPathComponent(tag))
            let names = ["QuickFile-\(tag).dmg", "QuickFile-\(tag).dmg.sha256"]
            let hash = String(repeating: "a", count: 64)
            provenance = ["schema_version": 1, "release_tag": tag, "internal_build": build, "trust": "ad-hoc/unnotarized",
                          "assets": names.map { ["name": $0, "bytes": 10, "sha256": hash] }]
            let assets: [[String: Any]] = (names + ["build-provenance.json"]).map { name in
                ["name": name, "state": "uploaded", "size": 10, "digest": "sha256:" + hash,
                 "browser_download_url": "https://github.com/haoyang7/QuickFile/releases/download/\(tag)/\(name)"]
            }
            records = [["tag_name": tag, "draft": false, "prerelease": tag.contains("-beta."), "assets": assets]]
        }

        func checker(emptyFirstPages: Int = 0) throws -> CommunityReleaseChecker {
            let receipt = try receiptDataOverride ?? JSONSerialization.data(withJSONObject: provenance, options: [.sortedKeys])
            var records = records
            for index in records.indices {
                var assets = records[index]["assets"] as! [[String: Any]]
                for assetIndex in assets.indices where assets[assetIndex]["name"] as? String == "build-provenance.json" {
                    assets[assetIndex]["size"] = receiptMetadataOverride?.size ?? receipt.count
                    assets[assetIndex]["digest"] = receiptMetadataOverride?.digest ?? "sha256:" + SHA256.hash(data: receipt)
                        .map { String(format: "%02x", $0) }.joined()
                }
                records[index]["assets"] = assets
            }
            let list = try JSONSerialization.data(withJSONObject: records, options: [.sortedKeys])
            let listStatus = listStatus, receiptStatus = receiptStatus
            let listURL = listFinalURL, receiptURL = receiptFinalURL
            return CommunityReleaseChecker { request, limit in
                let url = request.url!
                if url.host == "api.github.com" {
                    let page = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                        .first(where: { $0.name == "page" })?.value.flatMap(Int.init) ?? 1
                    var headers: [String: String] = [:]
                    if page <= emptyFirstPages {
                        headers["Link"] = "<https://api.github.com/repositories/1412789324/releases?per_page=100&page=\(page + 1)>; rel=\"next\""
                    }
                    return .init(data: page <= emptyFirstPages ? Data("[]".utf8) : list,
                                 statusCode: listStatus, url: listURL ?? url, headers: headers)
                }
                XCTAssertEqual(url.lastPathComponent, "build-provenance.json", "Checks must never download a DMG")
                XCTAssertEqual(limit, 65_536)
                return .init(data: receipt, statusCode: receiptStatus, url: receiptURL ?? url)
            }
        }
    }
}

// All mutable protocol bookkeeping is protected by the lock. XCTest expectations support concurrent fulfillment.
private final class TransportScenario: @unchecked Sendable {
    enum Mode: Sendable {
        case overflow(chunked: Bool)
        case waitForResponse
        case waitForBody
        case redirect(URL)
    }

    static let origin = URL(string: "https://github.com/haoyang7/QuickFile/releases/download/v0.1.0/build-provenance.json")!
    static let property = "QuickFileTransportScenario"
    let mode: Mode
    let initialURL: URL
    let ready = XCTestExpectation(description: "Protocol ready")
    let stopped = XCTestExpectation(description: "Protocol stopped")
    let released = XCTestExpectation(description: "Protocol released")
    private let lock = NSLock()
    private var urls: [URL] = []
    private var chunks = 0
    private var isStopped = false
    private weak var activeTask: URLSessionTask?
    private weak var activeSession: URLSession?
    private var taskWasObserved = false
    private var sessionWasObserved = false

    init(mode: Mode, initialURL: URL = TransportScenario.origin) {
        self.mode = mode
        self.initialURL = initialURL
    }

    func request() -> URLRequest {
        let request = NSMutableURLRequest(url: initialURL)
        URLProtocol.setProperty(self, forKey: Self.property, in: request)
        return request as URLRequest
    }

    func started(_ url: URL, task: URLSessionTask?) {
        lock.lock()
        urls.append(url)
        activeTask = task
        taskWasObserved = taskWasObserved || task != nil
        lock.unlock()
    }

    func observe(_ session: URLSession) {
        lock.lock()
        activeSession = session
        sessionWasObserved = true
        lock.unlock()
    }

    func nextChunkSize() -> Int? {
        lock.lock()
        defer { lock.unlock() }
        guard !isStopped else { return nil }
        guard chunks < 100 else { return 0 }
        chunks += 1
        return 512
    }

    func stop() {
        lock.lock()
        let first = !isStopped
        isStopped = true
        lock.unlock()
        if first { stopped.fulfill() }
    }

    func snapshot() -> (urls: [URL], chunks: Int, taskWasObserved: Bool, taskReleased: Bool,
                        sessionWasObserved: Bool, sessionReleased: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (urls, chunks, taskWasObserved, activeTask == nil, sessionWasObserved, activeSession == nil)
    }
}

// The subclass has no mutable fields; its scheduled stream and cancellation share the locked scenario.
private final class TransportProtocol: URLProtocol, @unchecked Sendable {
    private var scenario: TransportScenario? {
        URLProtocol.property(forKey: TransportScenario.property, in: request) as? TransportScenario
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let scenario, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        scenario.started(url, task: task)
        switch scenario.mode {
        case .waitForResponse:
            scenario.ready.fulfill()
            failIfStillWaiting()
        case .waitForBody:
            respond()
            client?.urlProtocol(self, didLoad: Data("[".utf8))
            scenario.ready.fulfill()
            failIfStillWaiting()
        case let .overflow(chunked):
            respond(headers: chunked ? ["Transfer-Encoding": "chunked"] : [:])
            streamChunk()
        case let .redirect(target):
            if url == scenario.initialURL {
                var next = request
                next.url = target
                let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1",
                                               headerFields: ["Location": target.absoluteString])!
                client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
                client?.urlProtocolDidFinishLoading(self)
            } else {
                respond()
                client?.urlProtocol(self, didLoad: Data("[]".utf8))
                client?.urlProtocolDidFinishLoading(self)
            }
        }
    }

    override func stopLoading() { scenario?.stop() }

    private func respond(headers: [String: String] = [:]) {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        XCTAssertEqual(response.expectedContentLength, -1)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    }

    private func streamChunk() {
        guard let count = scenario?.nextChunkSize() else { return }
        guard count > 0 else { client?.urlProtocolDidFinishLoading(self); return }
        client?.urlProtocol(self, didLoad: Data(repeating: 32, count: count))
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(10)) { [self] in streamChunk() }
    }

    private func failIfStillWaiting() {
        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(5)) { [weak self] in
            guard let self else { return }
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
        }
    }

    deinit { scenario?.released.fulfill() }
}
