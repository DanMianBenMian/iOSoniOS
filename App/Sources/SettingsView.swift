import SwiftUI

struct SettingsView: View {
    @Binding var config: VMConfig
    let onDismiss: () -> Void

    @State private var jitExplanation = false
    @State private var jitAvailable = DebugCapability.jitAvailable

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.canvas.ignoresSafeArea()
                List {
                    Section {
                        SettingRow(icon: "ant.fill", title: "启用 JIT",
                                   subtitle: jitAvailable
                                       ? "动态代码生成，虚拟 CPU 提速"
                                       : "不可用：未检测到调试权限",
                                   iconColor: (jitAvailable && config.enableJIT) ? Theme.iconJIT : Theme.textFaint) {
                            Toggle("", isOn: Binding(
                                get: { jitAvailable && config.enableJIT },
                                set: { config.enableJIT = $0 }
                            ))
                            .labelsHidden()
                            .tint(Theme.accent)
                            .disabled(!jitAvailable)
                            .opacity(jitAvailable ? 1 : 0.45)
                        }

                        if !jitAvailable {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 12)).foregroundColor(Theme.warn)
                                Text(DebugCapability.statusText)
                                    .font(.system(size: 11))
                                    .foregroundColor(Theme.warn.opacity(0.92))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(10)
                            .background(Theme.warn.opacity(0.09))
                            .cornerRadius(8)
                        }

                        Button {
                            withAnimation(.easeOut(duration: 0.25)) { jitExplanation.toggle() }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "questionmark.circle")
                                    .foregroundColor(Theme.textMuted)
                                Text("JIT 为什么需要调试器？")
                                    .font(.system(size: 12)).foregroundColor(Theme.textMuted)
                                Spacer()
                                Image(systemName: jitExplanation ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 11)).foregroundColor(Theme.textFaint)
                            }
                        }
                        .buttonStyle(.plain)

                        if jitExplanation {
                            Text("iOS 只允许带调试权限的进程申请可执行内存。当前用分发证书签名时，mmap 可能成功但执行会被系统拦截；换成开发者签名并附加 StikDebug 后才能真正跑 JIT。本 App 的安全探测不会执行代码，所以不会闪退。")
                                .font(.system(size: 11)).foregroundColor(Theme.textMuted)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    } header: {
                        Text("性能").foregroundColor(Theme.textFaint)
                    }

                    Section {
                        SettingRow(icon: "memorychip.fill", title: "设备内存", iconColor: Theme.iconMemory) {
                            Text(String(format: "%.1f GiB", DeviceProfile.totalRAMGB))
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(Theme.textMuted)
                        }
                        SettingRow(icon: "cpu.fill", title: "物理核心", iconColor: Theme.iconCPU) {
                            Text("\(DeviceProfile.physicalCores) 核")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(Theme.textMuted)
                        }
                        SettingRow(icon: "ipad", title: "机型", iconColor: Theme.iconInfo) {
                            Text(DeviceProfile.chipName)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(Theme.textMuted)
                        }
                    } header: {
                        Text("本机").foregroundColor(Theme.textFaint)
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        config.save()
                        onDismiss()
                    }.tint(Theme.accent)
                }
            }
        }
    }
}
