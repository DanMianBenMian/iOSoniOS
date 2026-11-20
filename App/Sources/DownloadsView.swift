import SwiftUI
import UniformTypeIdentifiers

/// In-app download page: firmware downloads inside the app with live progress,
/// plus importing an .ipsw already on the device.
struct DownloadsView: View {
    private let ipswURL = URL(string:
        "https://updates.cdn-apple.com/2026SpringSeed/fullrestores/140-21639/1B98799E-8A35-4D79-A826-78ABE1659FCF/iPad_Fall_2022_27.0_24A5370h_Restore.ipsw")!

    @StateObject private var downloader = FirmwareDownloader()
    @State private var localFiles: [String] = []
    @State private var showImporter = false
    @State private var importMessage: String?
    @State private var extracting = false
    @State private var extractMessage: String?
    @State private var notice: StorageNoticeSheet.Kind? = nil

    var body: some View {
        ZStack {
            Theme.canvas.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    sectionTitle("固件")
                    ipswCard
                    importCard
                    extractCard
                    sectionTitle("本机文件")
                    if localFiles.isEmpty { emptyCard }
                    else { ForEach(localFiles, id: \.self) { localCard($0) } }
                    hint
                }
                .padding(20)
            }
        }
        .navigationTitle("下载")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: scanLocal)
        .onChange(of: downloader.phase) { phase in
            if case .finished = phase { scanLocal() }
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.data],
                      allowsMultipleSelection: false) { result in
            handleImport(result)
        }
        .sheet(item: $notice) { kind in
            StorageNoticeSheet(kind: kind) {
                switch kind {
                case .download: startDownload()
                case .extract:
                    if let name = localFiles.first(where: { $0.hasSuffix(".ipsw") }) {
                        extractBootkc(name)
                    }
                }
            }
        }
    }

    private func sectionTitle(_ t: String) -> some View {
        Text(t).font(.system(size: 11, weight: .semibold))
            .foregroundColor(Theme.textFaint).textCase(.uppercase)
    }

    private var ipswCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(LinearGradient(colors: [Theme.iconFirmware.opacity(0.95),
                                                  Theme.iconFirmware.opacity(0.78)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: 29, height: 29)
                    .overlay(Image(systemName: "shippingbox.fill")
                        .font(.system(size: 13, weight: .semibold)).foregroundColor(.white))
                VStack(alignment: .leading, spacing: 2) {
                    Text("iPadOS 27 beta 2").font(.system(size: 14, weight: .medium))
                        .foregroundColor(Theme.text)
                    Text("24A5370h · iPad13,18/19 · A14")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Theme.textMuted)
                }
                Spacer()
                Text("10.73 GB").font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Theme.textFaint)
            }

            if downloader.isActive || isFinished {
                progressBlock
            }
            HStack(spacing: 10) {
                if downloader.isActive {
                    Button {
                        downloader.cancel()
                    } label: {
                        Label("取消", systemImage: "xmark.circle")
                            .font(.system(size: 13, weight: .medium))
                            .frame(maxWidth: .infinity).padding(.vertical, 11)
                    }
                    .nativeButton()
                } else {
                    Button {
                        notice = .download
                    } label: {
                        Label("下载到本机", systemImage: "arrow.down.circle.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(maxWidth: .infinity).padding(.vertical, 11)
                    }
                    .nativeButton(prominent: true)
                }
            }

            Text("直连 updates.cdn-apple.com，在本 App 内下载，完成后自动存进 Documents。中断可续传。")
                .font(.system(size: 10)).foregroundColor(Theme.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(Theme.surface)
        .cornerRadius(12)
    }

    private var isFinished: Bool {
        if case .finished = downloader.phase { return true }
        return false
    }

    private func startDownload() {
        downloader.start(url: ipswURL, suggestedName: "iPad_Fall_2022_27.0_24A5370h_Restore.ipsw")
    }

    private var progressBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.surfaceHi).frame(height: 6)
                    Capsule()
                        .fill(progressTint)
                        .frame(width: max(6, geo.size.width * CGFloat(downloader.progress)), height: 6)
                        .animation(.easeOut(duration: 0.25), value: downloader.progress)
                }
            }
            .frame(height: 6)

            HStack(spacing: 6) {
                Text(String(format: "%.1f%%", downloader.progress * 100))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(progressTint)
                Text("·").foregroundColor(Theme.textFaint)
                Text("\(fmt(downloader.receivedBytes)) / \(fmt(downloader.totalBytes))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Theme.textMuted)
                Spacer()
                if downloader.bytesPerSecond > 0, case .downloading = downloader.phase {
                    Text("\(fmt(Int64(downloader.bytesPerSecond)))/s")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Theme.textFaint)
                }
            }
        }
    }

    private var progressTint: Color {
        switch downloader.phase {
        case .failed: return Theme.danger
        case .finished: return Theme.ok
        default: return Theme.accent
        }
    }

    private var importCard: some View {
        Button {
            showImporter = true
        } label: {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Theme.iconDownload)
                    .frame(width: 29, height: 29)
                    .overlay(Image(systemName: "square.and.arrow.down.fill")
                        .font(.system(size: 13, weight: .semibold)).foregroundColor(.white))
                VStack(alignment: .leading, spacing: 2) {
                    Text("导入 IPSW").font(.system(size: 14, weight: .medium))
                        .foregroundColor(Theme.text)
                    Text(importMessage ?? "从「文件」里选一个 .ipsw 放进本 App")
                        .font(.system(size: 11))
                        .foregroundColor(messageTint(importMessage))
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12)).foregroundColor(Theme.textFaint)
            }
            .padding(14)
            .background(Theme.surface)
            .cornerRadius(12)
        }
        .buttonStyle(.plain)
    }

    /// Pulls kernelcache out of an imported IPSW: zip -> im4p -> LZFSE -> bootkc.
    private var extractCard: some View {
        let ipsw = localFiles.first { $0.hasSuffix(".ipsw") }
        let hasBootkc = FileManager.default.fileExists(
            atPath: RyLog.documentsURL.appendingPathComponent("bootkc").path)

        return VStack(alignment: .leading, spacing: 10) {
            Button {
                guard ipsw != nil else { return }
                notice = .extract
            } label: {
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Theme.iconBoot)
                        .frame(width: 29, height: 29)
                        .overlay(Image(systemName: "cpu")
                            .font(.system(size: 13, weight: .semibold)).foregroundColor(.white))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("从 IPSW 提取内核").font(.system(size: 14, weight: .medium))
                            .foregroundColor(Theme.text)
                        Text(extractMessage
                             ?? (ipsw == nil
                                 ? "先导入或下载一个 .ipsw"
                                 : "解出 kernelcache → bootkc"))
                            .font(.system(size: 11))
                            .foregroundColor(messageTint(extractMessage))
                    }
                    Spacer()
                    if extracting {
                        ProgressView().scaleEffect(0.8)
                    } else if hasBootkc {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(Theme.ok)
                    }
                }
                .padding(14)
                .background(Theme.surface)
                .cornerRadius(12)
            }
            .buttonStyle(.plain)
            .disabled(ipsw == nil || extracting)
            .opacity(ipsw == nil ? 0.55 : 1)
        }
    }

    private func extractBootkc(_ ipswName: String) {
        extracting = true
        extractMessage = "正在解压…"
        let docs = RyLog.documentsURL
        let src = docs.appendingPathComponent(ipswName)
        let out = docs.appendingPathComponent("bootkc")

        RyLog.log("ipsw", "extracting kernelcache from \(ipswName)", level: .info)
        DispatchQueue.global(qos: .userInitiated).async {
            var bytes: UInt64 = 0
            var detail = [CChar](repeating: 0, count: 256)
            let rc = src.path.withCString { sp in
                out.path.withCString { op in
                    ry_ipsw_extract_bootkc(sp, op, &bytes, &detail, detail.count)
                }
            }
            let message = String(cString: detail)
            DispatchQueue.main.async {
                extracting = false
                extractMessage = rc == 0 ? message : "失败：\(message)"
                RyLog.log("ipsw", rc == 0 ? "bootkc ready: \(message)" : "extract failed: \(message)",
                          level: rc == 0 ? .info : .error)
                scanLocal()
            }
        }
    }

    private var emptyCard: some View {
        HStack(spacing: 10) {
            Image(systemName: "tray").foregroundColor(Theme.textFaint)
            Text("还没有固件文件").font(.system(size: 12)).foregroundColor(Theme.textMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.surface)
        .cornerRadius(12)
    }

    private func localCard(_ name: String) -> some View {
        let url = RyLog.documentsURL.appendingPathComponent(name)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        return ShareLink(item: url) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Theme.iconFirmware)
                    .frame(width: 29, height: 29)
                    .overlay(Image(systemName: "doc.fill")
                        .font(.system(size: 13, weight: .semibold)).foregroundColor(.white))
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.system(size: 13, weight: .medium))
                        .foregroundColor(Theme.text).lineLimit(1)
                    Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Theme.textMuted)
                }
                Spacer()
                Image(systemName: "square.and.arrow.up").foregroundColor(Theme.textFaint)
            }
            .padding(14)
            .background(Theme.surface)
            .cornerRadius(12)
        }
        .buttonStyle(.plain)
    }

    private var hint: some View {
        Text("创建虚拟机时会自动使用这里的 .ipsw。测试版允许没有固件直接创建。")
            .font(.system(size: 10)).foregroundColor(Theme.textFaint)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func messageTint(_ message: String?) -> Color {
        guard let m = message else { return Theme.textMuted }
        if m.hasPrefix("失败") || m.contains("失败") || m.contains("取消") {
            return Theme.danger
        }
        return Theme.ok
    }

    private func fmt(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func scanLocal() {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: RyLog.documentsURL.path)) ?? []
        localFiles = names.filter { $0.hasSuffix(".ipsw") || $0.hasSuffix(".ipa") }.sorted()
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let src = urls.first else { return }
            let dest = RyLog.documentsURL.appendingPathComponent(src.lastPathComponent)
            let needsScope = src.startAccessingSecurityScopedResource()
            defer { if needsScope { src.stopAccessingSecurityScopedResource() } }
            do {
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.copyItem(at: src, to: dest)
                importMessage = "已导入 \(src.lastPathComponent)"
                RyLog.log("import", "copied \(src.lastPathComponent) to Documents", level: .info)
                scanLocal()
            } catch {
                importMessage = "导入失败：\(error.localizedDescription)"
                RyLog.log("import", "failed: \(error.localizedDescription)", level: .error)
            }
        case .failure(let error):
            importMessage = "导入取消或失败：\(error.localizedDescription)"
        }
    }
}
