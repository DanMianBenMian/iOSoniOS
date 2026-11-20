import Foundation
import Combine

/// In-app firmware downloader with progress, cancel and resume.
///
/// Uses URLSession's download task (not a WebView or Safari hand-off), so the
/// app can show a real progress bar and keep the file. Resume data is kept so a
/// dropped connection can continue instead of restarting 10 GB.
@MainActor
final class FirmwareDownloader: NSObject, ObservableObject {
    enum Phase: Equatable {
        case idle
        case downloading
        case paused
        case finished(URL)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var progress: Double = 0        // 0...1
    @Published private(set) var receivedBytes: Int64 = 0
    @Published private(set) var totalBytes: Int64 = 0
    @Published private(set) var bytesPerSecond: Double = 0

    private var session: URLSession!
    private var task: URLSessionDownloadTask?
    private var resumeData: Data?
    private var lastSampleTime = Date()
    private var lastSampleBytes: Int64 = 0
    private var destinationName = "firmware.ipsw"

    override init() {
        super.init()
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 60 * 60 * 8
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }

    var isActive: Bool {
        switch phase {
        case .downloading, .paused: return true
        default: return false
        }
    }

    func start(url: URL, suggestedName: String) {
        guard !isActive else { return }
        destinationName = suggestedName
        phase = .downloading
        progress = 0
        receivedBytes = 0
        totalBytes = 0
        lastSampleTime = Date()
        lastSampleBytes = 0

        if let data = resumeData {
            task = session.downloadTask(withResumeData: data)
        } else {
            task = session.downloadTask(with: url)
        }
        resumeData = nil
        task?.resume()
    }

    func cancel() {
        task?.cancel { [weak self] data in
            guard let self else { return }
            Task { @MainActor in
                self.resumeData = data
                self.phase = .idle
                self.progress = 0
                self.receivedBytes = 0
                self.bytesPerSecond = 0
            }
        }
        task = nil
    }
}

extension FirmwareDownloader: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession,
                                downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.receivedBytes = totalBytesWritten
            if totalBytesExpectedToWrite > 0 {
                self.totalBytes = totalBytesExpectedToWrite
                self.progress = min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
            }
            let now = Date()
            let dt = now.timeIntervalSince(self.lastSampleTime)
            if dt >= 0.5 {
                let delta = totalBytesWritten - self.lastSampleBytes
                self.bytesPerSecond = Double(delta) / dt
                self.lastSampleTime = now
                self.lastSampleBytes = totalBytesWritten
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession,
                                downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        // Move out of the temp location before this delegate returns.
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let name = downloadTask.response?.suggestedFilename ?? "firmware.ipsw"
        let dest = docs.appendingPathComponent(name)
        try? fm.removeItem(at: dest)
        do {
            try fm.moveItem(at: location, to: dest)
            Task { @MainActor [weak self] in
                self?.phase = .finished(dest)
                self?.progress = 1
                RyLog.log("download", "saved \(name) (\(dest.path))", level: .info)
            }
        } catch {
            Task { @MainActor [weak self] in
                self?.phase = .failed(error.localizedDescription)
                RyLog.log("download", "move failed: \(error.localizedDescription)", level: .error)
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession,
                                task: URLSessionTask,
                                didCompleteWithError error: Error?) {
        guard let error else { return }
        let ns = error as NSError
        Task { @MainActor [weak self] in
            guard let self else { return }
            if ns.code == NSURLErrorCancelled {
                self.phase = .idle
            } else {
                self.phase = .failed(error.localizedDescription)
                RyLog.log("download", "failed: \(error.localizedDescription)", level: .error)
            }
        }
    }
}
