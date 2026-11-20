import SwiftUI

/// A headless confirmation sheet shown before a long/heavy firmware operation.
/// Warns about AEA encryption, slow decryption and the free-space requirement,
/// with an icon, title, plain explanation and an explicit 退出 button.
struct StorageNoticeSheet: View {
    enum Kind: Identifiable {
        case download, extract
        var id: Int { self == .download ? 0 : 1 }
    }

    let kind: Kind
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Theme.canvas.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 18) {
                // icon tile
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        LinearGradient(colors: [Theme.iconFirmware.opacity(0.95),
                                                Theme.iconFirmware.opacity(0.75)],
                                       startPoint: .top, endPoint: .bottom)
                    )
                    .frame(width: 48, height: 48)
                    .overlay(
                        Image(systemName: "externaldrive.fill.badge.wifi")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundColor(.white)
                    )

                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundColor(Theme.text)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 12) {
                    bullet(icon: "lock.shield.fill", color: Theme.iconFirmware,
                           text: "iPadOS 27 固件可能带 AEA 加密，解密要在设备上完成，耗时较长，期间请保持 App 在前台。")
                    bullet(icon: "internaldrive.fill", color: Theme.iconMemory,
                           text: "请预留足够储存空间：完整 IPSW 约 10.7 GB，解压出的内核还要额外空间，建议至少空出 25 GB。")
                    bullet(icon: "bolt.fill", color: Theme.iconBoot,
                           text: "空间不足或中途切到后台，都可能导致下载/提取失败；下载支持断点续传，重进可继续。")
                }
                .padding(14)
                .background(Theme.surface)
                .cornerRadius(12)

                Spacer(minLength: 8)

                HStack(spacing: 10) {
                    Button {
                        dismiss()
                    } label: {
                        Text("退出")
                            .font(.system(size: 14, weight: .medium))
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                    }
                    .nativeButton()

                    Button {
                        dismiss()
                        onConfirm()
                    } label: {
                        Text(confirmLabel)
                            .font(.system(size: 14, weight: .semibold))
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                    }
                    .nativeButton(prominent: true)
                }
            }
            .padding(22)
        }
    }

    private var title: String {
        switch kind {
        case .download: return "下载前须知"
        case .extract:  return "提取前须知"
        }
    }

    private var subtitle: String {
        switch kind {
        case .download: return "即将从 Apple 服务器下载完整 IPSW，请先确认储存空间。"
        case .extract:  return "即将解密并解包 IPSW 提取内核，这一步会比较慢。"
        }
    }

    private var confirmLabel: String {
        switch kind {
        case .download: return "开始下载"
        case .extract:  return "开始提取"
        }
    }

    @ViewBuilder
    private func bullet(icon: String, color: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(color.opacity(0.18))
                .frame(width: 24, height: 24)
                .overlay(
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(color)
                )
            Text(text)
                .font(.system(size: 11.5))
                .foregroundColor(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
