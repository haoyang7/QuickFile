import AppKit
import Combine
import QuickFileCore

/// A Services payload is only a location hint. The existing Open-panel flow
/// obtains the destination; this object never reads or authorizes that location.
@MainActor
final class QuickFileFolderService: NSObject, ObservableObject {
    struct Request: Identifiable, Equatable {
        let id = UUID()
        let folderHint: URL
    }

    enum RequestError: Error, LocalizedError, Equatable {
        case invalidSelection, requestPending

        var errorDescription: String? {
            switch self {
            case .invalidSelection:
                return QuickFileLocalization.text(.init("请仅选择一个文件夹，再使用 QuickFile 服务。"))
            case .requestPending:
                return QuickFileLocalization.text(.init("QuickFile 中已有文件夹请求。请先处理或取消该请求。"))
            }
        }
    }

    static let maximumURLBytes = 16_384
    @Published private(set) var pendingRequest: Request?
    @Published private(set) var couldNotOpenWindow = false
    @Published private(set) var isSelectingFolder = false
    private let openCreationWindow: @MainActor () async -> Bool
    private var openingRequestID: UUID?

    init(openCreationWindow: (@MainActor () async -> Bool)? = nil) {
        self.openCreationWindow = openCreationWindow ?? Self.openOwnCreationWindow
    }

    @objc(newFileWithQuickFile:userData:error:)
    func newFileWithQuickFile(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error errorPointer: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        errorPointer.pointee = nil
        do {
            try receive(pasteboard)
        } catch let failure as RequestError {
            errorPointer.pointee = failure.errorDescription as NSString?
        } catch {
            errorPointer.pointee = RequestError.invalidSelection.errorDescription as NSString?
        }
    }

    @discardableResult
    func receive(_ pasteboard: NSPasteboard) throws -> Request {
        guard pendingRequest == nil, !isSelectingFolder else { throw RequestError.requestPending }
        let request = Request(folderHint: try Self.folderHint(from: pasteboard))
        couldNotOpenWindow = false
        pendingRequest = request
        openPendingWindow()
        return request
    }

    private func openPendingWindow() {
        guard openingRequestID == nil, let request = pendingRequest else { return }
        openingRequestID = request.id
        Task { @MainActor in
            guard pendingRequest?.id == request.id else {
                openingRequestID = nil
                openPendingWindow()
                return
            }
            let opened = await openCreationWindow()
            openingRequestID = nil
            // Opening may finish after cancel, selection, or a newer request.
            guard pendingRequest?.id == request.id else {
                openPendingWindow()
                return
            }
            couldNotOpenWindow = !opened
        }
    }

    static func folderHint(from pasteboard: NSPasteboard) throws -> URL {
        // Inspect the Services pasteboard only. Do not use readObjects options
        // that resolve content types or inspect the supplied filesystem paths.
        // URL.path may preserve %00; validate the URL path after one decode.
        guard pasteboard.name != .general,
              let items = pasteboard.pasteboardItems, items.count == 1,
              let data = items[0].data(forType: .fileURL),
              !data.isEmpty, data.count <= maximumURLBytes,
              let text = String(data: data, encoding: .utf8),
              let components = URLComponents(string: text),
              components.scheme == "file",
              components.host == nil || components.host == "" || components.host == "localhost",
              components.user == nil, components.password == nil, components.port == nil,
              components.query == nil, components.fragment == nil,
              components.percentEncodedPath.hasPrefix("/"),
              let path = components.percentEncodedPath.removingPercentEncoding,
              !path.contains("\0"),
              let url = components.url, url.isFileURL, url.baseURL == nil,
              url.path.hasPrefix("/") else {
            throw RequestError.invalidSelection
        }
        return url
    }

    func cancel(requestID: UUID) {
        guard pendingRequest?.id == requestID else { return }
        pendingRequest = nil
        couldNotOpenWindow = false
    }

    func selectFolder(
        requestID: UUID,
        viewModel: QuickFileViewModel,
        finderIntegration: FinderIntegrationViewModel,
        isPresentationAvailable: @MainActor () -> Bool,
        willPresent: @MainActor () -> Void = {},
        choose: @MainActor (URL) async -> URL?
    ) async {
        guard let request = pendingRequest, request.id == requestID,
              !isSelectingFolder, !viewModel.isAuthorizationCheckBusy,
              isPresentationAvailable() else { return }
        // App-scoped admission prevents two windows consuming the same request.
        isSelectingFolder = true
        defer { isSelectingFolder = false }
        var didSelect = false
        await viewModel.selectDestinationFolder(choosing: {
            guard pendingRequest?.id == requestID, isPresentationAvailable() else { return nil }
            willPresent()
            guard pendingRequest?.id == requestID, isPresentationAvailable() else { return nil }
            let selectedURL = await choose(request.folderHint)
            guard pendingRequest?.id == requestID, isPresentationAvailable(),
                  let selectedURL else { return nil }
            // Reselecting the same URL must also invalidate the old verification.
            finderIntegration.cancelVerification()
            didSelect = true
            return selectedURL
        })
        if didSelect { cancel(requestID: requestID) }
    }

    private static func openOwnCreationWindow() async -> Bool {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.allowsRunningApplicationSubstitution = false
        return await withCheckedContinuation { continuation in
            NSWorkspace.shared.open(
                [QuickFileAppRoute.create.url],
                withApplicationAt: Bundle.main.bundleURL,
                configuration: configuration
            ) { _, error in
                continuation.resume(returning: error == nil)
            }
        }
    }
}
