import CryptoKit
import Foundation

struct CommunityRelease: Equatable, Sendable {
    let tag: String
    let version: String
    let build: String
    let pageURL: URL
}

enum CommunityReleaseCheckResult: Equatable, Sendable {
    case updateAvailable(CommunityRelease)
    case upToDate
    case noPublishedRelease
}

enum CommunityReleaseCheckError: Error, Equatable, Sendable {
    case invalidCurrentVersion
    case invalidResponse
    case rateLimited
    case requestFailed
    case responseTooLarge
    case missingProvenance
}

struct CommunityReleaseChecker: Sendable {
    static let releasesPage = URL(string: "https://github.com/haoyang7/QuickFile/releases")!
    private static let api = "https://api.github.com/repos/haoyang7/QuickFile/releases?per_page=100"
    // GitHub uses this immutable repository ID in the fixed repository's pagination links.
    private static let canonicalReleasesPath = "/repositories/1412789324/releases"
    private static let listLimit = 1_048_576
    private static let provenanceLimit = 65_536
    private static let maximumPages = 3

    struct Response: Sendable {
        let data: Data
        let statusCode: Int
        let url: URL
        var headers: [String: String] = [:]

        fileprivate func header(_ name: String) -> String? {
            headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
    }

    typealias Fetch = @Sendable (URLRequest, Int) async throws -> Response
    private let fetch: Fetch

    init(fetch: @escaping Fetch = { request, limit in try await CommunityReleaseChecker.fetchResponse(request, limit: limit) }) {
        self.fetch = fetch
    }

    static func installedVersionName(version: String, releaseTag: String?) -> String {
        guard let releaseTag, let tag = Tag(releaseTag), tag.version.text == version,
              let beta = tag.beta else { return version }
        return "\(version) Beta \(beta)"
    }

    func check(version: String, build: String, releaseTag: String? = nil,
               includingBetas: Bool) async throws -> CommunityReleaseCheckResult {
        guard let currentVersion = Version(version), let currentBuild = Self.number(build), currentBuild > 0 else {
            throw CommunityReleaseCheckError.invalidCurrentVersion
        }
        let currentTag: Tag?
        if let releaseTag {
            guard let tag = Tag(releaseTag), tag.version == currentVersion else {
                throw CommunityReleaseCheckError.invalidCurrentVersion
            }
            currentTag = tag
        } else { currentTag = nil }
        try Task.checkCancellation()
        var candidates: [(release: ReleaseRecord, tag: Tag)] = []
        for page in 1...Self.maximumPages {
            let url = Self.listURL(page: page)
            let response = try await load(url, limit: Self.listLimit)
            try Self.validateStatus(response.statusCode)
            let records: [ReleaseRecord]
            do { records = try JSONDecoder().decode([ReleaseRecord].self, from: response.data) }
            catch { throw CommunityReleaseCheckError.invalidResponse }
            guard records.count <= 100 else { throw CommunityReleaseCheckError.invalidResponse }
            candidates += records.compactMap { record in
                guard !record.draft, let tag = Tag(record.tagName),
                      record.prerelease == (tag.beta != nil), includingBetas || tag.beta == nil else { return nil }
                return (record, tag)
            }
            guard try Self.hasNextPage(response, page: page) else { break }
            guard page < Self.maximumPages else { throw CommunityReleaseCheckError.responseTooLarge }
        }
        try Task.checkCancellation()
        guard let selected = candidates.max(by: { $0.tag < $1.tag }) else { return .noPublishedRelease }
        guard candidates.filter({ $0.release.tagName == selected.release.tagName }).count == 1 else {
            throw CommunityReleaseCheckError.invalidResponse
        }
        let publishedBuild = try await verifiedBuild(for: selected.release)
        try Task.checkCancellation()
        let isNewer: Bool
        if let currentTag {
            isNewer = currentTag < selected.tag ||
                (currentTag == selected.tag && currentBuild < publishedBuild.value)
        } else {
            // Older packages lack release identity; keep their version/build comparison.
            isNewer = currentVersion < selected.tag.version ||
                (currentVersion == selected.tag.version && currentBuild < publishedBuild.value)
        }
        if isNewer {
            return .updateAvailable(CommunityRelease(
                tag: selected.release.tagName, version: selected.tag.version.text,
                build: publishedBuild.text,
                pageURL: Self.releasesPage.appendingPathComponent("tag").appendingPathComponent(selected.release.tagName)
            ))
        }
        return .upToDate
    }

    private func verifiedBuild(for release: ReleaseRecord) async throws -> (text: String, value: UInt64) {
        let dmgName = "QuickFile-\(release.tagName).dmg"
        var required: [String: AssetRecord] = [:]
        for name in [dmgName, dmgName + ".sha256", "build-provenance.json"] {
            let matches = release.assets.filter { $0.name == name }
            guard matches.count == 1, let asset = matches.first, asset.state == "uploaded", asset.size > 0,
                  asset.browserDownloadURL == Self.assetURL(tag: release.tagName, name: name).absoluteString else {
                throw CommunityReleaseCheckError.missingProvenance
            }
            required[name] = asset
        }
        guard let receipt = required["build-provenance.json"], receipt.size <= Self.provenanceLimit else {
            throw CommunityReleaseCheckError.responseTooLarge
        }
        let response = try await load(Self.assetURL(tag: release.tagName, name: "build-provenance.json"),
                                      limit: Self.provenanceLimit)
        if response.statusCode == 404 { throw CommunityReleaseCheckError.missingProvenance }
        try Self.validateStatus(response.statusCode)
        let provenance: Provenance
        do { provenance = try JSONDecoder().decode(Provenance.self, from: response.data) }
        catch { throw CommunityReleaseCheckError.missingProvenance }
        guard provenance.schemaVersion == 1, provenance.releaseTag == release.tagName,
              provenance.trust == "ad-hoc/unnotarized",
              let build = Self.number(provenance.internalBuild), build > 0 else {
            throw CommunityReleaseCheckError.missingProvenance
        }
        // These hashes bind public release metadata; they do not authenticate a signing identity.
        for name in [dmgName, dmgName + ".sha256"] {
            let entries = provenance.assets.filter { $0.name == name }
            guard entries.count == 1, let entry = entries.first, let asset = required[name],
                  entry.bytes == asset.size, Self.validSHA256(entry.sha256),
                  asset.digest == nil || asset.digest == "sha256:" + entry.sha256 else {
                throw CommunityReleaseCheckError.missingProvenance
            }
        }
        guard receipt.size == response.data.count,
              receipt.digest == nil || receipt.digest == "sha256:" + SHA256.hash(data: response.data)
                .map({ String(format: "%02x", $0) }).joined() else {
            throw CommunityReleaseCheckError.missingProvenance
        }
        return (provenance.internalBuild, build)
    }

    private func load(_ url: URL, limit: Int) async throws -> Response {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpShouldHandleCookies = false
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("QuickFile-Community-Update-Check", forHTTPHeaderField: "User-Agent")
        do {
            try Task.checkCancellation()
            let response = try await fetch(request, limit)
            try Task.checkCancellation()
            guard Self.accepts(response.url, for: url) else { throw CommunityReleaseCheckError.invalidResponse }
            guard response.data.count <= limit else { throw CommunityReleaseCheckError.responseTooLarge }
            return response
        } catch is CancellationError { throw CancellationError() }
        catch let error as CommunityReleaseCheckError { throw error }
        catch {
            try Task.checkCancellation()
            throw CommunityReleaseCheckError.requestFailed
        }
    }

    private static func validateStatus(_ status: Int) throws {
        if status == 403 || status == 429 { throw CommunityReleaseCheckError.rateLimited }
        guard status == 200 else { throw CommunityReleaseCheckError.requestFailed }
    }

    private static func listURL(page: Int) -> URL {
        URL(string: api + (page == 1 ? "" : "&page=\(page)"))!
    }

    private static func hasNextPage(_ response: Response, page: Int) throws -> Bool {
        guard let link = response.header("Link") else { return false }
        guard !link.isEmpty else { throw CommunityReleaseCheckError.invalidResponse }
        var next: URL?
        for part in link.split(separator: ",") {
            let fields = part.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            let relations = fields.dropFirst().filter { $0.hasPrefix("rel=") }
            guard relations.count == 1, let relation = relations.first,
                  let target = fields.first, target.hasPrefix("<"), target.hasSuffix(">"),
                  let url = URL(string: String(target.dropFirst().dropLast())) else {
                throw CommunityReleaseCheckError.invalidResponse
            }
            var namesText = String(relation.dropFirst(4))
            if namesText.hasPrefix("\"") {
                guard namesText.count >= 2, namesText.hasSuffix("\"") else {
                    throw CommunityReleaseCheckError.invalidResponse
                }
                namesText = String(namesText.dropFirst().dropLast())
            }
            guard !namesText.contains("\"") else { throw CommunityReleaseCheckError.invalidResponse }
            let names = namesText.split(separator: " ")
            guard !names.isEmpty else { throw CommunityReleaseCheckError.invalidResponse }
            guard names.contains("next") else { continue }
            guard next == nil,
                  isNextPageURL(url, after: page) else { throw CommunityReleaseCheckError.invalidResponse }
            next = url
        }
        return next != nil
    }

    private static func isNextPageURL(_ url: URL, after page: Int) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "https", components.host == "api.github.com",
              components.user == nil, components.password == nil, components.fragment == nil,
              components.port == nil || components.port == 443,
              [listURL(page: page + 1).path, canonicalReleasesPath].contains(components.percentEncodedPath),
              let items = components.queryItems, items.count == 2 else { return false }
        // Continue constructing requests from our fixed endpoint; never follow the Link target.
        return items.contains(URLQueryItem(name: "per_page", value: "100")) &&
            items.contains(URLQueryItem(name: "page", value: String(page + 1)))
    }

    private static func assetURL(tag: String, name: String) -> URL {
        releasesPage.appendingPathComponent("download").appendingPathComponent(tag).appendingPathComponent(name)
    }

    fileprivate static func accepts(_ url: URL, for original: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil, url.fragment == nil,
              url.port == nil || url.port == 443 else { return false }
        if original.host == "api.github.com" { return url == original }
        return ["github.com", "api.github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com"]
            .contains(url.host ?? "")
    }

    private static func number(_ text: String) -> UInt64? {
        guard !text.isEmpty, text.utf8.count <= 18, text.utf8.allSatisfy({ (48...57).contains($0) }),
              text == "0" || !text.hasPrefix("0") else { return nil }
        return UInt64(text)
    }

    private static func validSHA256(_ text: String) -> Bool {
        text.utf8.count == 64 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private struct Version: Equatable, Comparable {
        let components: [UInt64]
        let text: String

        init?(_ text: String) {
            let parts = text.split(separator: ".", omittingEmptySubsequences: false)
            let components = parts.compactMap { CommunityReleaseChecker.number(String($0)) }
            guard parts.count == 3, components.count == 3 else { return nil }
            self.components = components
            self.text = text
        }

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.components.lexicographicallyPrecedes(rhs.components) }
    }

    private struct Tag: Comparable {
        let version: Version
        let beta: UInt64?

        init?(_ text: String) {
            guard text.hasPrefix("v") else { return nil }
            let parts = text.dropFirst().components(separatedBy: "-beta.")
            guard (1...2).contains(parts.count), let version = Version(parts[0]) else { return nil }
            self.version = version
            if parts.count == 2 {
                guard let beta = CommunityReleaseChecker.number(parts[1]), beta > 0 else { return nil }
                self.beta = beta
            } else { beta = nil }
        }

        static func < (lhs: Self, rhs: Self) -> Bool {
            if lhs.version != rhs.version { return lhs.version < rhs.version }
            switch (lhs.beta, rhs.beta) {
            case let (left?, right?): return left < right
            case (_?, nil): return true
            default: return false
            }
        }
    }

    private struct ReleaseRecord: Decodable {
        let tagName: String
        let draft: Bool
        let prerelease: Bool
        let assets: [AssetRecord]
        enum CodingKeys: String, CodingKey { case tagName = "tag_name", draft, prerelease, assets }
    }

    private struct AssetRecord: Decodable {
        let name: String
        let state: String
        let size: Int
        let digest: String?
        let browserDownloadURL: String
        enum CodingKeys: String, CodingKey {
            case name, state, size, digest
            case browserDownloadURL = "browser_download_url"
        }
    }

    private struct Provenance: Decodable {
        let schemaVersion: Int
        let releaseTag: String
        let internalBuild: String
        let trust: String
        let assets: [Asset]
        struct Asset: Decodable { let name: String; let bytes: Int; let sha256: String }
        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version", releaseTag = "release_tag", internalBuild = "internal_build"
            case trust, assets
        }
    }

    // Tests replace the loading protocol and observe its session lifetime. Production uses the controlled
    // ephemeral configuration without either hook.
    static func fetchResponse(_ request: URLRequest, limit: Int, protocolClasses: [AnyClass]? = nil,
                              sessionObserver: (@Sendable (URLSession) -> Void)? = nil) async throws -> Response {
        guard let original = request.url else { throw CommunityReleaseCheckError.invalidResponse }
        let configuration = URLSessionConfiguration.ephemeral
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 20
        let session = URLSession(configuration: configuration, delegate: RedirectPolicy(original: original), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        sessionObserver?(session)
        return try await withTaskCancellationHandler {
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse, let url = response.url, accepts(url, for: original) else {
                throw CommunityReleaseCheckError.invalidResponse
            }
            if response.statusCode != 404 || original.host == "api.github.com" {
                try validateStatus(response.statusCode)
            }
            guard response.expectedContentLength <= Int64(limit) else { throw CommunityReleaseCheckError.responseTooLarge }
            var data = Data()
            for try await byte in bytes {
                guard data.count < limit else { throw CommunityReleaseCheckError.responseTooLarge }
                data.append(byte)
            }
            try Task.checkCancellation()
            var headers: [String: String] = [:]
            for (key, value) in response.allHeaderFields {
                if let key = key as? String, let value = value as? String { headers[key] = value }
            }
            return Response(data: data, statusCode: response.statusCode, url: url, headers: headers)
        } onCancel: {
            session.invalidateAndCancel()
        }
    }
}

private final class RedirectPolicy: NSObject, URLSessionTaskDelegate {
    let original: URL
    init(original: URL) { self.original = original }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, CommunityReleaseChecker.accepts(url, for: original) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
