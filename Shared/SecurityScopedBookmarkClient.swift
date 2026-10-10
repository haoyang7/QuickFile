import Foundation

// Bookmark operations may run concurrently on independent requests. Injected clients
// must synchronize mutable captures; live callbacks capture no mutable state.
struct SecurityScopedBookmarkClient: Sendable {
    typealias BookmarkCreator = @Sendable (URL) throws -> Data
    typealias BookmarkResolver = @Sendable (Data) throws -> ResolvedSecurityScopedBookmark
    typealias SecurityScopeStarter = @Sendable (URL) -> Bool
    typealias SecurityScopeStopper = @Sendable (URL) -> Void

    let createPersistentBookmark: BookmarkCreator
    let createTransferBookmark: BookmarkCreator
    let resolvePersistentBookmark: BookmarkResolver
    let resolveTransferBookmark: BookmarkResolver
    let startAccessing: SecurityScopeStarter
    let stopAccessing: SecurityScopeStopper

    static var live: SecurityScopedBookmarkClient {
        SecurityScopedBookmarkClient(
            createPersistentBookmark: { url in
                try url.bookmarkData(options: [.withSecurityScope])
            },
            createTransferBookmark: { url in
                try url.bookmarkData(options: [])
            },
            resolvePersistentBookmark: { bookmarkData in
                var isStale = false
                let url = try URL(
                    resolvingBookmarkData: bookmarkData,
                    options: [
                        .withSecurityScope,
                        .withoutUI,
                        .withoutMounting,
                        .withoutImplicitStartAccessing
                    ],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                return ResolvedSecurityScopedBookmark(url: url, isStale: isStale)
            },
            resolveTransferBookmark: { bookmarkData in
                var isStale = false
                let url = try URL(
                    resolvingBookmarkData: bookmarkData,
                    options: [
                        .withoutUI,
                        .withoutMounting,
                        .withoutImplicitStartAccessing
                    ],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                return ResolvedSecurityScopedBookmark(url: url, isStale: isStale)
            },
            startAccessing: { $0.startAccessingSecurityScopedResource() },
            stopAccessing: { $0.stopAccessingSecurityScopedResource() }
        )
    }
}
