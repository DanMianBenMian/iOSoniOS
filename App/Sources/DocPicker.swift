import UIKit
import UniformTypeIdentifiers

/// UIKit document picker, presented directly from the app's top view controller.
///
/// Why not SwiftUI's `.fileImporter`: on iPadOS 27 beta the SwiftUI modifier
/// opens the picker but never delivers the selection (the user picks a file and
/// nothing comes back). The UIKit path is the battle-tested one — same fix already
/// proven in the RyBox app on this exact device.
///
/// - `asCopy: false` — security-scoped URL to the ORIGINAL file. Required here:
///   a 10 GB IPSW must not be auto-duplicated by the system into our container.
///   We copy it into Documents ourselves, once, while holding the scope.
enum DocPicker {

    enum PickerError: LocalizedError {
        case noHost
        case unreadable(String)
        public var errorDescription: String? {
            switch self {
            case .noHost: return "找不到可用的视图控制器来打开文件选择器"
            case .unreadable(let n): return "无法读取所选文件：\(n)"
            }
        }
    }

    /// Strong ref: UIDocumentPickerViewController holds its delegate WEAKLY.
    fileprivate static var retainedDelegate: PickerDelegate?

    /// Present the picker. `completion` runs on the main thread.
    static func present(asCopy: Bool = false,
                        completion: @escaping (Result<URL, Error>) -> Void) {
        DispatchQueue.main.async {
            guard let host = topViewController() else {
                completion(.failure(PickerError.noHost))
                return
            }
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item],
                                                        asCopy: asCopy)
            picker.allowsMultipleSelection = false
            picker.shouldShowFileExtensions = true
            let delegate = PickerDelegate(asCopy: asCopy, completion: completion)
            retainedDelegate = delegate           // keep alive across presentation
            picker.delegate = delegate
            host.present(picker, animated: true)
        }
    }

    /// Walk every window of every scene, prefer the KEY one, climb to top VC.
    static func topViewController() -> UIViewController? {
        var windows: [UIWindow] = []
        for scene in UIApplication.shared.connectedScenes {
            guard let ws = scene as? UIWindowScene else { continue }
            windows.append(contentsOf: ws.windows)
        }
        let sorted = windows.sorted { a, b in
            if a.isKeyWindow != b.isKeyWindow { return a.isKeyWindow && !b.isKeyWindow }
            return a.windowLevel < b.windowLevel
        }
        for w in sorted {
            guard !w.isHidden, w.alpha > 0.01 else { continue }
            var vc = w.rootViewController
            while let presented = vc?.presentedViewController,
                  !(presented is UIDocumentPickerViewController) {
                vc = presented
            }
            if let vc = vc, vc.view.window != nil || vc === w.rootViewController {
                return vc
            }
        }
        return windows.first?.rootViewController
    }
}

/// Forwards the picked URL. Implements BOTH picker delegate callbacks: some
/// iOS betas call the legacy single-document one instead of the plural one.
private final class PickerDelegate: NSObject, UIDocumentPickerDelegate {
    let completion: (Result<URL, Error>) -> Void
    let asCopy: Bool

    init(asCopy: Bool, completion: @escaping (Result<URL, Error>) -> Void) {
        self.asCopy = asCopy
        self.completion = completion
    }

    func documentPicker(_ controller: UIDocumentPickerViewController,
                        didPickDocumentsAt urls: [URL]) {
        if let url = urls.first { deliver(url) }
        DocPicker.retainedDelegate = nil
    }

    func documentPicker(_ controller: UIDocumentPickerViewController,
                        didPickDocumentAt url: URL) {
        deliver(url)
        DocPicker.retainedDelegate = nil
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        DocPicker.retainedDelegate = nil
    }

    private func deliver(_ url: URL) {
        if !asCopy { _ = url.startAccessingSecurityScopedResource() }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            completion(.failure(DocPicker.PickerError.unreadable(url.lastPathComponent)))
            return
        }
        completion(.success(url))
    }
}
