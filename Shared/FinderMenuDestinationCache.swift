import Foundation

/// Finder's selection, without reading metadata. Values ignored by the resolver are also
/// ignored here, so an observed container can be prepared before its first menu opens.
public struct FinderMenuSelection: Equatable, Sendable {
    public let context: FinderMenuContext
    public let targetedURL: URL?
    public let selectedItemURLs: [URL]

    public init(context: FinderMenuContext, targetedURL: URL?, selectedItemURLs: [URL]) {
        self.context = context
        self.targetedURL = context == .sidebar ? nil : targetedURL
        self.selectedItemURLs = context == .container || (context == .toolbar && targetedURL != nil)
            ? [] : selectedItemURLs
    }
}

/// Immutable identity captured before an actionable menu is published. A path by itself
/// must never be promoted to a trusted destination when the user later clicks the menu.
public struct FinderMenuDestination: Equatable, Sendable {
    public let folder: URL
    public let identity: DirectoryIdentity

    public init(folder: URL, identity: DirectoryIdentity) {
        self.folder = folder.standardizedFileURL
        self.identity = identity
    }

    /// Filesystem work: call only off the Finder menu callback.
    public static func prepare(for selection: FinderMenuSelection) -> FinderMenuDestination? {
        guard let folder = FinderContextResolver().destinationFolder(
            for: selection.context, targetedURL: selection.targetedURL,
            selectedItemURLs: selection.selectedItemURLs
        ), let identity = try? DirectoryIdentity.capture(at: folder) else { return nil }
        return FinderMenuDestination(folder: folder, identity: identity)
    }
}

/// Memory snapshots with bounded, asynchronous preparation and an optional menu deadline.
/// By default, at most
/// two reads can be stalled, and no work is queued behind them. Observation uses at most
/// one slot and leaves one for demand. A stalled observation plus a distinct stalled
/// demand (or two distinct stalled demands) can still exhaust the budget; there is no
/// cancellation mechanism for the underlying synchronous filesystem reads.
/// A cache miss fails closed.
/// Exact selection equality deliberately includes the entire selection, never a prefix.
/// Its memory-only comparison is O(selection size); real menu latency still needs measurement.
public final class FinderMenuDestinationCache: @unchecked Sendable {
    public enum Snapshot: Equatable, Sendable {
        /// Preparation for this exact selection is already running or was just admitted.
        case loading
        /// No result is cached and this request could not start preparation. No work is queued.
        case busy
        case ready(FinderMenuDestination)
        case unavailable
    }

    public typealias Preparer = @Sendable (FinderMenuSelection) -> FinderMenuDestination?
    private struct Entry {
        let selection: FinderMenuSelection
        var snapshot: Snapshot
        var generation: UUID?
        // The trace that produced this snapshot, not an in-flight refresh of it.
        var proofTimingID: String?
    }

    private let lock = NSLock()
    private let queue = DispatchQueue(
        label: "com.haoyoung.QuickFile.finder-destination-preparation",
        qos: .userInitiated, attributes: .concurrent
    )
    private let prepare: Preparer
    private let standardizeURL: @Sendable (URL) -> URL
    private let maximumEntries: Int
    private let maximumConcurrentPreparations: Int
    private var entries: [Entry] = []
    private struct Preparation {
        let generation: UUID
        let selections: [FinderMenuSelection]
        let isObservation: Bool
        let timingID: String?
        let completion: DispatchGroup
    }
    // Separate from the LRU: eviction/invalidation must not hide a still-running read.
    private var preparations: [Preparation] = []

    public convenience init(
        maximumEntries: Int = 16,
        maximumConcurrentPreparations: Int = 2,
        prepare: @escaping Preparer = { FinderMenuDestination.prepare(for: $0) }
    ) {
        self.init(maximumEntries: maximumEntries,
                  maximumConcurrentPreparations: maximumConcurrentPreparations,
                  standardizeURL: { $0.standardizedFileURL }, prepare: prepare)
    }

    // Inject the potentially filesystem-dependent operation for deterministic lock tests.
    init(
        maximumEntries: Int = 16,
        maximumConcurrentPreparations: Int = 2,
        standardizeURL: @escaping @Sendable (URL) -> URL,
        prepare: @escaping Preparer
    ) {
        self.maximumEntries = max(1, maximumEntries)
        self.maximumConcurrentPreparations = max(1, maximumConcurrentPreparations)
        self.standardizeURL = standardizeURL
        self.prepare = prepare
    }

    /// Returns a previously prepared result or the current admission state, without
    /// filesystem work. Refreshes on use so a legitimately replaced directory becomes
    /// usable again, without ever changing existing actions.
    public func currentSnapshot(for selection: FinderMenuSelection, timing: CreationTiming? = nil) -> Snapshot {
        snapshot(for: selection, isObservation: false, timing: timing)
    }

    /// Gives a cold, local preparation the remainder of the menu's shared deadline.
    /// Timeout only stops waiting; a stalled read keeps its preparation slot.
    public func menuSnapshot(
        for selection: FinderMenuSelection, waitingUntil deadline: DispatchTime,
        timing: CreationTiming? = nil
    ) -> Snapshot {
        let current = currentSnapshot(for: selection, timing: timing)
        guard current == .loading else { return current }
        lock.lock()
        let completion = preparations.first { $0.selections.contains(selection) }?.completion
        lock.unlock()
        _ = completion?.wait(timeout: deadline)
        // Never resubscribe an invalidated selection to the result of an older read.
        return cachedSnapshot(for: selection) ?? .unavailable
    }

    /// A single directory proof can warm both contexts. Toolbar's general file-parent
    /// fallback is deliberately NOT used here: only successful directory proofs fan out.
    public func prewarmObservedDirectory(at url: URL) {
        _ = snapshot(for: FinderMenuSelection(
            context: .container, targetedURL: url, selectedItemURLs: []
        ), isObservation: true)
    }

    private func snapshot(for selection: FinderMenuSelection, isObservation: Bool, timing: CreationTiming? = nil) -> Snapshot {
        lock.lock()
        var entry: Entry
        if let index = entries.firstIndex(where: { $0.selection == selection }) {
            entry = entries.remove(at: index)
        } else {
            entry = Entry(selection: selection, snapshot: .busy, generation: nil, proofTimingID: nil)
        }
        let alreadyPreparing = preparations.contains { $0.selections.contains(selection) }
        let hasCapacity = preparations.count < maximumConcurrentPreparations
        let canPrewarm = !isObservation || (
            preparations.count < maximumConcurrentPreparations - 1
                && !preparations.contains { $0.isObservation }
        )
        let shouldPrepare = !alreadyPreparing && hasCapacity && canPrewarm
        let generation = shouldPrepare ? UUID() : nil
        var selections = [selection]
        if selection.context == .container, let url = selection.targetedURL {
            selections.append(FinderMenuSelection(context: .toolbar, targetedURL: url, selectedItemURLs: []))
        }
        // An active toolbar read already owns this target. Do not start a second read
        // simply because observation or a container menu arrived after that read.
        let overlapsActive = preparations.contains { active in
            selections.contains { active.selections.contains($0) }
        }
        let admittedGeneration = overlapsActive ? nil : generation
        let preparationTiming = admittedGeneration == nil ? nil : CreationTiming.begin(
            isObservation ? "destination-prewarm" : "destination-preparation", parentID: timing?.id
        )
        let completion = DispatchGroup()
        if let admittedGeneration {
            completion.enter()
            entry.generation = admittedGeneration
            preparations.append(Preparation(generation: admittedGeneration,
                                            selections: selections, isObservation: isObservation,
                                            timingID: preparationTiming?.id, completion: completion))
        }
        switch entry.snapshot {
        case .loading, .busy:
            // Re-evaluate cold misses on every request: a previous capacity denial
            // does not mean work is queued, and a later request can retry admission.
            entry.snapshot = alreadyPreparing || admittedGeneration != nil ? .loading : .busy
        case .ready, .unavailable:
            break
        }
        let snapshot = entry.snapshot
        let linkedTimingID: String?
        switch snapshot {
        case .ready, .unavailable: linkedTimingID = entry.proofTimingID
        case .loading, .busy:
            linkedTimingID = preparations.first { $0.selections.contains(selection) }?.timingID
        }
        if let admittedGeneration {
            for alias in selections.dropFirst() {
                let previousEntry = entries.first { $0.selection == alias }
                var previous = previousEntry?.snapshot ?? .loading
                if previous == .busy { previous = .loading }
                entries.removeAll { $0.selection == alias }
                entries.append(Entry(selection: alias, snapshot: previous, generation: admittedGeneration,
                                     proofTimingID: previousEntry?.proofTimingID))
            }
        }
        // Keep the requested entry ahead of an optional alias in the LRU, including
        // when the configured cache has room for only one snapshot.
        entries.append(entry)
        while entries.count > maximumEntries { entries.removeFirst() }
        lock.unlock()

        if let linkedTimingID { timing?.mark("menu.destination.preparation.link", relatedID: linkedTimingID) }
        if let admittedGeneration {
            let prepare = self.prepare
            preparationTiming?.mark("preparation.submitted")
            queue.async { [weak self] in
                defer { completion.leave() }
                preparationTiming?.mark("preparation.entered")
                let destination = prepare(selection)
                if destination == nil { preparationTiming?.mark("preparation.unavailable") }
                else { preparationTiming?.mark("preparation.ready") }
                guard let self else {
                    preparationTiming?.finish(outcome: "owner-ended")
                    return
                }
                preparationTiming?.mark("preparation.cache.publish.begin")
                let accepted = self.complete(destination, for: selection, generation: admittedGeneration,
                                             timingID: preparationTiming?.id)
                if accepted { preparationTiming?.mark("preparation.cache.accepted") }
                else { preparationTiming?.mark("preparation.cache.discarded") }
                preparationTiming?.mark("preparation.cache.publish.end")
                preparationTiming?.finish(outcome: accepted ? (destination == nil ? "unavailable" : "ready") : "discarded")
            }
        }
        return snapshot
    }

    public func invalidate(_ selection: FinderMenuSelection) {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll { $0.selection == selection }
    }

    // Read-only inspection for deterministic lifecycle tests; does not schedule a refresh.
    func cachedSnapshot(for selection: FinderMenuSelection) -> Snapshot? {
        lock.lock(); defer { lock.unlock() }
        return entries.first { $0.selection == selection }?.snapshot
    }

    var cachedEntryCount: Int {
        lock.lock(); defer { lock.unlock() }
        return entries.count
    }

    var activePreparationCount: Int {
        lock.lock(); defer { lock.unlock() }
        return preparations.count
    }

    private func complete(
        _ destination: FinderMenuDestination?, for selection: FinderMenuSelection, generation: UUID,
        timingID: String?
    ) -> Bool {
        // URL normalization can consult the filesystem. Finish the alias proof on the
        // preparation worker before taking the shared snapshot lock, retaining its slot
        // until publication. No cache state is consulted or changed outside the lock.
        let provesAlias: Bool
        if selection.context == .container, let destination, let target = selection.targetedURL {
            provesAlias = destination.folder == standardizeURL(target)
        } else {
            provesAlias = false
        }

        lock.lock(); defer { lock.unlock() }
        preparations.removeAll { $0.generation == generation }
        var accepted = false
        // Invalidated/evicted entries are never resubscribed to the old read. Only
        // entries still carrying its generation may receive the immutable result.
        for index in entries.indices where entries[index].generation == generation {
            if entries[index].selection == selection {
                entries[index].snapshot = destination.map(Snapshot.ready) ?? .unavailable
                entries[index].proofTimingID = timingID
                accepted = true
            } else if provesAlias, let destination {
                entries[index].snapshot = .ready(destination)
                entries[index].proofTimingID = timingID
                accepted = true
            }
            // Failed container proof says nothing about toolbar file-parent fallback.
            entries[index].generation = nil
        }
        return accepted
    }
}
