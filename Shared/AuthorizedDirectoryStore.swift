import Foundation
import QuickFileCore

// Immutable dependencies carry their own concurrency contracts: repository transactions
// retain their file locks, while bookmark callbacks must provide Sendable captures.
public struct AuthorizedDirectoryStore: Sendable {
    public typealias StoreError = AuthorizedDirectoryStoreError
    typealias BookmarkCreator = SecurityScopedBookmarkClient.BookmarkCreator
    typealias BookmarkResolver = SecurityScopedBookmarkClient.BookmarkResolver
    typealias SecurityScopeStarter = SecurityScopedBookmarkClient.SecurityScopeStarter
    typealias SecurityScopeStopper = SecurityScopedBookmarkClient.SecurityScopeStopper

    private let repository: AuthorizedDirectoryRepository
    private let policy: AuthorizedDirectoryPolicy
    private let bookmarkClient: SecurityScopedBookmarkClient

    public init() {
        repository = AuthorizedDirectoryRepository(
            containerURL: FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: QuickFileConfiguration.appGroupIdentifier
            )
        )
        policy = AuthorizedDirectoryPolicy(fileManager: .default)
        bookmarkClient = .live
    }

    init(
        defaults: UserDefaults?,
        storageDirectory: URL? = nil,
        fileManager: FileManager = .default,
        persistentBookmarkCreator: @escaping BookmarkCreator,
        transferBookmarkCreator: @escaping BookmarkCreator,
        persistentBookmarkResolver: @escaping BookmarkResolver,
        transferBookmarkResolver: @escaping BookmarkResolver,
        startAccessing: @escaping SecurityScopeStarter = { $0.startAccessingSecurityScopedResource() },
        stopAccessing: @escaping SecurityScopeStopper = { $0.stopAccessingSecurityScopedResource() }
    ) {
        repository = AuthorizedDirectoryRepository(defaults: defaults, storageDirectory: storageDirectory)
        policy = AuthorizedDirectoryPolicy(fileManager: fileManager)
        bookmarkClient = SecurityScopedBookmarkClient(
            createPersistentBookmark: persistentBookmarkCreator,
            createTransferBookmark: transferBookmarkCreator,
            resolvePersistentBookmark: persistentBookmarkResolver,
            resolveTransferBookmark: transferBookmarkResolver,
            startAccessing: startAccessing,
            stopAccessing: stopAccessing
        )
    }

    public var isAvailable: Bool {
        repository.isAvailable
    }

    @discardableResult
    public func authorize(_ directoryURL: URL) throws -> AuthorizedDirectory {
        guard repository.isAvailable else {
            throw StoreError.sharedDefaultsUnavailable
        }

        let snapshot = try repository.loadSnapshot()
        let originals = snapshot.authorizations
        let selectedDirectoryURL = directoryURL.standardizedFileURL
        try policy.validate(selectedDirectoryURL)
        let canonicalDirectoryURL = AuthorizedDirectoryPolicy.canonicalURL(selectedDirectoryURL)
        let canonicalDirectoryComponents = canonicalDirectoryURL.pathComponents
        let selectedDirectoryIdentity = try DirectoryIdentity.capture(at: canonicalDirectoryURL)

        let persistentBookmarkData: Data
        let transferBookmarkData: Data
        do {
            persistentBookmarkData = try bookmarkClient.createPersistentBookmark(selectedDirectoryURL)
            transferBookmarkData = try bookmarkClient.createTransferBookmark(selectedDirectoryURL)
        } catch {
            throw StoreError.bookmarkCreationFailed(error)
        }

        // A new explicit grant must not resolve every unrelated/offline bookmark.
        // Persisted path/identity are only cheap candidate filters. A directory
        // recreated at the old path must not resolve the moved/offline old grant.
        // Matching hints still need live resolution and identity checks before
        // record ID reuse. Legacy records without hints are preserved; successful
        // inventory refreshes populate their hints without changing their IDs.
        // All potentially blocking work remains outside the repository write lock.
        let existingIndex = originals.firstIndex { authorization in
            guard authorization.canonicalPathHint == canonicalDirectoryURL.path,
                  authorization.directoryIdentityHint == selectedDirectoryIdentity else { return false }
            guard let resolvedBookmark = try? bookmarkClient.resolvePersistentBookmark(
                authorization.persistentBookmarkData
            ) else {
                return false
            }
            let resolvedURL = AuthorizedDirectoryPolicy.canonicalURL(resolvedBookmark.url)
            guard resolvedURL.pathComponents == canonicalDirectoryComponents else { return false }
            return (try? DirectoryIdentity.capture(at: resolvedURL)) == selectedDirectoryIdentity
        }
        // Resolution/bookmark creation can block. Reject replacement of the
        // selected target during that work; no old grant or hint may authorize it.
        let currentSelectedURL = AuthorizedDirectoryPolicy.canonicalURL(selectedDirectoryURL)
        guard currentSelectedURL.pathComponents == canonicalDirectoryComponents,
              (try? DirectoryIdentity.capture(at: currentSelectedURL)) == selectedDirectoryIdentity else {
            throw StoreError.authorizationChanged
        }

        let id = existingIndex.map { originals[$0].id } ?? UUID()
        let replacement = storedAuthorization(
            id: id,
            persistentBookmarkData: persistentBookmarkData,
            transferBookmarkData: transferBookmarkData,
            canonicalPathHint: canonicalDirectoryURL.path,
            directoryIdentityHint: selectedDirectoryIdentity
        )
        // The repository checks the persistent table generation under the write
        // lock before committing. Even insert-then-revoke changes that generation.
        // A conflict requires a new explicit authorization, never an internal retry.
        return try repository.update(expectedGeneration: snapshot.generation) { authorizations in
            if let existingIndex {
                authorizations[existingIndex] = replacement
            } else {
                authorizations.append(replacement)
            }

            return AuthorizedDirectory(id: id, url: canonicalDirectoryURL, isBookmarkStale: false)
        }
    }

    /// Resolve only a currently selected record. Unrelated offline grants cannot delay
    /// a direct selection; inventory enumeration remains a separate diagnostic operation.
    public func authorizedDirectory(withID id: AuthorizedDirectory.ID) throws -> AuthorizedDirectory {
        guard let record = try repository.load().first(where: { $0.id == id }) else {
            throw StoreError.authorizationChanged
        }
        let resolved: ResolvedSecurityScopedBookmark
        do { resolved = try bookmarkClient.resolvePersistentBookmark(record.persistentBookmarkData) }
        catch { throw StoreError.bookmarkResolutionFailed(error) }
        return AuthorizedDirectory(id: record.id,
            url: AuthorizedDirectoryPolicy.canonicalURL(resolved.url), isBookmarkStale: resolved.isStale)
    }

    public func loadAuthorizedDirectories() throws -> [AuthorizedDirectory] {
        let inventory = try loadAuthorizedDirectoryInventory()
        guard inventory.unavailableDirectories.isEmpty else {
            throw StoreError.authorizationResolutionFailed(
                unresolvedCount: inventory.unavailableDirectories.count
            )
        }
        return inventory.availableDirectories
    }

    public func loadAuthorizedDirectoryInventory() throws -> AuthorizedDirectoryInventory {
        var availableDirectories: [AuthorizedDirectory] = []
        var unavailableDirectories: [UnavailableAuthorizedDirectory] = []

        for authorization in try repository.load() {
            do {
                let resolvedBookmark = try bookmarkClient.resolvePersistentBookmark(
                    authorization.persistentBookmarkData
                )
                availableDirectories.append(
                    AuthorizedDirectory(
                        id: authorization.id,
                        url: AuthorizedDirectoryPolicy.canonicalURL(resolvedBookmark.url),
                        isBookmarkStale: resolvedBookmark.isStale
                    )
                )
            } catch {
                unavailableDirectories.append(
                    UnavailableAuthorizedDirectory(id: authorization.id)
                )
            }
        }

        availableDirectories.sort {
            $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending
        }
        unavailableDirectories.sort { $0.id.uuidString < $1.id.uuidString }
        return AuthorizedDirectoryInventory(
            availableDirectories: availableDirectories,
            unavailableDirectories: unavailableDirectories
        )
    }

    public func refreshTransferBookmarks() throws {
        var authorizations = try repository.load()
        let originals = authorizations
        var failedAuthorizationIDs: [UUID] = []
        var firstRefreshError: Error?
        var didChange = false

        for index in authorizations.indices {
            do {
                let resolvedBookmark = try bookmarkClient.resolvePersistentBookmark(
                    authorizations[index].persistentBookmarkData
                )
                guard bookmarkClient.startAccessing(resolvedBookmark.url) else {
                    throw StoreError.securityScopeUnavailable
                }
                defer { bookmarkClient.stopAccessing(resolvedBookmark.url) }

                let persistentBookmarkData = resolvedBookmark.isStale
                    ? try bookmarkClient.createPersistentBookmark(resolvedBookmark.url)
                    : authorizations[index].persistentBookmarkData
                authorizations[index] = storedAuthorization(
                    id: authorizations[index].id,
                    persistentBookmarkData: persistentBookmarkData,
                    transferBookmarkData: try bookmarkClient.createTransferBookmark(resolvedBookmark.url),
                    canonicalPathHint: AuthorizedDirectoryPolicy.canonicalURL(resolvedBookmark.url).path,
                    directoryIdentityHint: try DirectoryIdentity.capture(at: resolvedBookmark.url)
                )
                didChange = true
            } catch {
                failedAuthorizationIDs.append(authorizations[index].id)
                firstRefreshError = firstRefreshError ?? error
            }
        }

        if didChange {
            try repository.update { current in
                for (original, refreshed) in zip(originals, authorizations) where original != refreshed {
                    // A revoke or reauthorization after the snapshot wins over this refresh.
                    if let index = current.firstIndex(of: original) {
                        current[index] = refreshed
                    }
                }
            }
        }
        if let firstRefreshError {
            throw StoreError.bookmarkRefreshFailed(
                failedAuthorizationIDs: failedAuthorizationIDs,
                underlyingError: firstRefreshError
            )
        }
    }

    @discardableResult
    public func revoke(_ authorizationID: AuthorizedDirectory.ID) throws -> Bool {
        try repository.update { authorizations in
            let originalCount = authorizations.count
            authorizations.removeAll { $0.id == authorizationID }
            return authorizations.count != originalCount
        }
    }

    @discardableResult
    public func revokeUnavailableAuthorizations(
        _ authorizationIDs: Set<AuthorizedDirectory.ID>
    ) throws -> Set<AuthorizedDirectory.ID> {
        guard !authorizationIDs.isEmpty else { return [] }

        var unavailableAuthorizations: [AuthorizedDirectory.ID: StoredDirectoryAuthorization] = [:]
        // Resolution can wait on an offline volume, so recheck the selected
        // candidates outside the write lock and preserve any that have recovered.
        for authorization in try repository.load() where authorizationIDs.contains(authorization.id) {
            do {
                _ = try bookmarkClient.resolvePersistentBookmark(authorization.persistentBookmarkData)
            } catch {
                unavailableAuthorizations[authorization.id] = authorization
            }
        }
        guard !unavailableAuthorizations.isEmpty else { return [] }

        return try repository.update { authorizations in
            var removedIDs: Set<AuthorizedDirectory.ID> = []
            authorizations.removeAll { authorization in
                // A concurrent reauthorization wins even when its bookmark data
                // is identical: the complete record includes a new revision.
                guard unavailableAuthorizations[authorization.id] == authorization else { return false }
                removedIDs.insert(authorization.id)
                return true
            }
            return removedIDs
        }
    }

    // Access is admitted by the final locked record check after the scope starts.
    // A revoke before that check excludes the old revision. A revoke after it
    // does not cancel the admitted operation, which runs without the store lock.
    public func withAccess<Result>(
        to destinationFolder: URL,
        authorizationID: AuthorizedDirectory.ID? = nil,
        timing: CreationTiming? = nil,
        perform operation: () throws -> Result
    ) throws -> Result {
        timing?.mark("authorization.begin")
        defer { timing?.mark("authorization.end") }
        let destinationFolder = AuthorizedDirectoryPolicy.canonicalURL(destinationFolder)
        var firstResolutionError: Error?
        var resolvedAuthorizationCount = 0
        var matchingAuthorizations: [(record: StoredDirectoryAuthorization, url: URL, originalIndex: Int)] = []
        var matchingAuthorizationCount = 0

        var authorizationChanged = false
        func tryAccess(record: StoredDirectoryAuthorization, url: URL) throws -> Result? {
            let currentBeforeScope = try {
                timing?.mark("authorization.revision.before-scope.begin")
                defer { timing?.mark("authorization.revision.before-scope.end") }
                do {
                    let current = try repository.contains(record)
                    if current { timing?.mark("authorization.revision.before-scope.current") }
                    else { timing?.mark("authorization.revision.before-scope.changed") }
                    return current
                } catch {
                    timing?.mark("authorization.revision.before-scope.failed")
                    throw error
                }
            }()
            guard currentBeforeScope else {
                authorizationChanged = true
                return nil
            }
            timing?.mark("authorization.scope.begin")
            guard bookmarkClient.startAccessing(url) else {
                timing?.mark("authorization.scope.rejected")
                return nil
            }
            timing?.mark("authorization.scope.started")
            defer {
                bookmarkClient.stopAccessing(url)
                timing?.mark("authorization.scope.stopped")
            }
            // Starting the scope may block. This second check is the admission
            // linearization point, serialized with revocation by the repository
            // lock. Only original candidates can be used, including fallbacks.
            let currentAfterScope = try {
                timing?.mark("authorization.revision.after-scope.begin")
                defer { timing?.mark("authorization.revision.after-scope.end") }
                do {
                    let current = try repository.contains(record)
                    if current { timing?.mark("authorization.revision.after-scope.current") }
                    else { timing?.mark("authorization.revision.after-scope.changed") }
                    return current
                } catch {
                    timing?.mark("authorization.revision.after-scope.failed")
                    throw error
                }
            }()
            guard currentAfterScope else {
                authorizationChanged = true
                return nil
            }
            timing?.mark("authorization.admitted")
            return .some(try operation())
        }

        let authorizations = try {
            timing?.mark("authorization.table.begin")
            defer { timing?.mark("authorization.table.end") }
            do {
                let records = try repository.load()
                timing?.mark("authorization.table.loaded")
                return records
            } catch {
                timing?.mark("authorization.table.failed")
                throw error
            }
        }()
        // A saved-directory selection must not silently use an overlapping grant after revocation.
        // Existing Finder callers pass nil and retain the established fallback policy.
        // Hints only prioritize work; they never establish containment or access. A
        // likely exact grant can avoid resolving unrelated/offline records first.
        // Keep every original candidate, including legacy and stale-hint records.
        let eligible = authorizations.enumerated().filter {
            authorizationID == nil || $0.element.id == authorizationID
        }
        let destinationPath = destinationFolder.path
        let candidates = eligible.filter { $0.element.canonicalPathHint == destinationPath }
            + eligible.filter { $0.element.canonicalPathHint != destinationPath }
        for (originalIndex, authorization) in candidates {
            let authorizedURL: URL
            do {
                authorizedURL = try {
                    timing?.mark("authorization.bookmark.begin")
                    defer { timing?.mark("authorization.bookmark.end") }
                    do {
                        let resolvedBookmark = try bookmarkClient.resolveTransferBookmark(
                            authorization.transferBookmarkData
                        )
                        let url = AuthorizedDirectoryPolicy.canonicalURL(resolvedBookmark.url)
                        timing?.mark("authorization.bookmark.resolved")
                        return url
                    } catch {
                        timing?.mark("authorization.bookmark.failed")
                        throw error
                    }
                }()
            } catch {
                firstResolutionError = firstResolutionError ?? error
                continue
            }
            resolvedAuthorizationCount += 1
            guard Self.directory(authorizedURL, contains: destinationFolder) else { continue }
            matchingAuthorizationCount += 1

            // An exact directory grant is maximally specific. Admit it before resolving
            // later, unrelated bookmarks. Failed admission still discovers all fallbacks.
            // Operation errors escape this loop; an admitted write is never retried.
            if authorizedURL.pathComponents == destinationFolder.pathComponents {
                if let result = try tryAccess(record: authorization, url: authorizedURL) { return result }
            } else {
                matchingAuthorizations.append((record: authorization, url: authorizedURL, originalIndex: originalIndex))
            }
        }

        guard matchingAuthorizationCount > 0 else {
            if resolvedAuthorizationCount == 0, let firstResolutionError {
                timing?.mark("authorization.unresolved")
                throw StoreError.bookmarkResolutionFailed(firstResolutionError)
            }
            timing?.mark("authorization.no-match")
            throw StoreError.directoryNotAuthorized
        }

        matchingAuthorizations.sort {
            let leftDepth = $0.url.pathComponents.count
            let rightDepth = $1.url.pathComponents.count
            if leftDepth != rightDepth { return leftDepth > rightDepth }
            // Prioritizing a hint must not reorder equally specific parent fallbacks.
            return $0.originalIndex < $1.originalIndex
        }

        for authorization in matchingAuthorizations {
            if let result = try tryAccess(record: authorization.record, url: authorization.url) {
                return result
            }
        }
        if authorizationChanged {
            timing?.mark("authorization.changed")
            throw StoreError.authorizationChanged
        }
        timing?.mark("authorization.scope-unavailable")
        throw StoreError.securityScopeUnavailable
    }

    public static func directory(_ directoryURL: URL, contains candidateURL: URL) -> Bool {
        AuthorizedDirectoryPolicy.directory(directoryURL, contains: candidateURL)
    }

    private func storedAuthorization(
        id: UUID,
        persistentBookmarkData: Data,
        transferBookmarkData: Data,
        canonicalPathHint: String,
        directoryIdentityHint: DirectoryIdentity
    ) -> StoredDirectoryAuthorization {
        StoredDirectoryAuthorization(
            id: id,
            persistentBookmarkData: persistentBookmarkData,
            transferBookmarkData: transferBookmarkData,
            canonicalPathHint: canonicalPathHint,
            directoryIdentityHint: directoryIdentityHint
        )
    }
}
