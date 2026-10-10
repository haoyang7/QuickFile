import Combine
import Foundation
import QuickFileCore

/// The application shares admission, while each editor owns its visible result.
final class TemplatePreviewWorker: @unchecked Sendable {
    static let shared = TemplatePreviewWorker()

    private let lock = NSLock()
    private var isRunning = false
    private let render: @Sendable (TemplatePreviewRequest) -> Result<TemplatePreviewOutput, TemplatePreviewError>

    init(
        render: @escaping @Sendable (TemplatePreviewRequest) -> Result<TemplatePreviewOutput, TemplatePreviewError> = {
            TemplatePreview.render($0)
        }
    ) {
        self.render = render
    }

    fileprivate func tryBegin() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isRunning else { return false }
        isRunning = true
        return true
    }

    fileprivate func finish() {
        lock.lock()
        isRunning = false
        lock.unlock()
    }

    fileprivate func run(_ request: TemplatePreviewRequest) async -> Result<TemplatePreviewOutput, TemplatePreviewError> {
        await BackgroundWork.run { [self, request] in
            // Cancellation or editor dismissal cannot release a synchronous render's slot.
            defer { finish() }
            return render(request)
        }
    }
}

@MainActor
final class TemplatePreviewController: ObservableObject {
    @Published private(set) var result: Result<TemplatePreviewOutput, TemplatePreviewError>?
    @Published private(set) var isWorking = false
    @Published private(set) var busyElsewhere = false

    private let worker: TemplatePreviewWorker
    private var isActive = false
    private var generation = UUID()

    init(worker: TemplatePreviewWorker = .shared) {
        self.worker = worker
    }

    func activate() {
        isActive = true
    }

    func deactivate() {
        isActive = false
        invalidate()
    }

    func invalidate() {
        // Most keystrokes happen with no preview. Do not publish unchanged nil/
        // false values or manufacture a new token for every ordinary edit.
        guard isWorking || result != nil || busyElsewhere else { return }
        generation = UUID()
        if result != nil { result = nil }
        if busyElsewhere { busyElsewhere = false }
    }

    /// Only explicit preview actions call this; draft edits invalidate without rendering.
    @discardableResult
    func request(content: String, fileExtension: String) -> Task<Void, Never>? {
        guard isActive, !isWorking else { return nil }
        result = nil
        busyElsewhere = false
        guard worker.tryBegin() else {
            busyElsewhere = true
            return nil
        }

        let request: TemplatePreviewRequest
        do {
            request = try TemplatePreviewRequest(content: content, fileExtension: fileExtension)
        } catch {
            worker.finish()
            result = .failure((error as? TemplatePreviewError) ?? .renderingFailed)
            return nil
        }

        isWorking = true
        let generation = generation
        let worker = worker
        // Capture only the bounded request and a weak controller across the suspension.
        return Task { [weak self, worker, request] in
            let result = await worker.run(request)
            self?.finish(result, generation: generation)
        }
    }

    private func finish(_ result: Result<TemplatePreviewOutput, TemplatePreviewError>, generation: UUID) {
        isWorking = false
        guard isActive, self.generation == generation else { return }
        self.result = result
    }
}
