import Foundation

/// Requests TDLib downloads with de-duplication and priorities. Progress and completion arrive as
/// updateFile and are read through `TelegramStore.latest(_:)`.
final class FileService {
    enum Priority: Int32 {
        case background = 1
        case avatar = 4
        case prefetch = 8
        case visible = 24
        /// The user explicitly asked for this file.
        case requested = 32
    }

    private let session: TelegramSession
    private var requested: [Int32: Priority] = [:]

    init(session: TelegramSession) {
        self.session = session
    }

    /// The freshest state of `file`.
    func latest(_ file: TDFile) -> TDFile { session.store.latest(file) }

    func localPath(_ file: TDFile) -> String? { latest(file).completedPath }

    /// Starts (or reprioritizes) a download unless the file is already on disk.
    func download(_ file: TDFile, priority: Priority) {
        let current = latest(file)
        guard current.completedPath == nil, current.local.canBeDownloaded else { return }
        if let previous = requested[file.id], previous.rawValue >= priority.rawValue, current.local.isDownloadingActive {
            return
        }
        requested[file.id] = priority
        session.post(DownloadFile(fileID: file.id, priority: priority.rawValue))
    }

    /// Stops a download the user started and no longer wants.
    func cancel(_ file: TDFile) {
        requested[file.id] = nil
        session.post(CancelDownloadFile(fileID: file.id))
    }

    /// Download progress in 0...1, or nil when nothing is known.
    func progress(_ file: TDFile) -> Double? {
        let current = latest(file)
        let total = max(current.size, current.expectedSize)
        guard total > 0 else { return nil }
        return min(1, Double(current.local.downloadedSize) / Double(total))
    }
}
