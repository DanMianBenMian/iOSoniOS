import SwiftUI

/// In-app download page: firmware straight from Apple's CDN, plus the IPAs
/// already staged in the app's Documents folder.
struct DownloadsView: View {
    private let ipswURL = URL(string:
        "https://updates.cdn-apple.com/2026SpringSeed/fullrestores/140-21639/1B98799E-8A35-4D79-A826-78ABE1659FCF/iPad_Fall_2022_27.0_24A5370h_Restore.ipsw")!

    @State private var localFiles: [String] = []

    var body: some View {
        ZStack {
            Theme.canvas.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    sectionTitle("固件")
                    ipswCard
                    sectionTitle("本机文件")
                    if localFiles.isEmpty {
                        emptyCard
                    } else {
                        ForEach(localFiles, id: \.self) { name in
                            localCard(name)
                        }
                    }
                    hint
                }
                .padding(20)
            }
        }
        .navigationTitle("下载")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .onAppear(perform: scanLocal)
    }

    private func sectionTitle(_ t: String) -> some View {
        Text(t).font(.system(size: 11, weight: .semibold))
            .foregroundColor(Theme.textFaint)
            .textCase(.uppercase)
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
            }

            Text("10.73 GB · 直连 updates.cdn-apple.com，不经过本机，支持断点续传。")
                .font(.system(size: 11)).foregroundColor(Theme.textMuted)

            Link(destination: ipswURL) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill")
                    Text("用 Safari 下载").font(.system(size: 14, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .nativeButton(prominent: true)

            Text("下载完成后，用「导入固件」把 .ipsw 放进这台设备的 Documents，创建虚拟机时就会用到。")
                .font(.system(size: 10)).foregroundColor(Theme.textFaint)
        }
        .padding(14)
        .background(Theme.surface)
        .cornerRadius(12)
    }

    private var emptyCard: some View {
        HStack(spacing: 10) {
            Image(systemName: "tray").foregroundColor(Theme.textFaint)
            Text("还没有放入固件文件").font(.system(size: 12)).foregroundColor(Theme.textMuted)
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
                    .fill(Theme.iconDownload)
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
        Text("隧道只用于本 App 之外的分发。固件下载走 Apple 服务器，与隧道无关。")
            .font(.system(size: 10)).foregroundColor(Theme.textFaint)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func scanLocal() {
        let fm = FileManager.default
        let docs = RyLog.documentsURL
        let names = (try? fm.contentsOfDirectory(atPath: docs.path)) ?? []
        localFiles = names.filter { $0.hasSuffix(".ipsw") || $0.hasSuffix(".ipa") }.sorted()
    }
}
