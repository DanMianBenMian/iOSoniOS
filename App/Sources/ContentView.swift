import SwiftUI

struct ContentView: View {
    @State private var config: VMConfig? = VMConfig.load()
    @State private var showConfig = false
    @State private var showSettings = false

    var body: some View {
        Group {
            if let cfg = config {
                NavigationStack {
                    MainView(config: cfg,
                             onReconfigure: { showConfig = true },
                             onSettings: { showSettings = true })
                }
                .sheet(isPresented: $showConfig) {
                    ConfigView(config: cfg) { newConfig in
                        showConfig = false
                        config = newConfig
                    }
                }
                .sheet(isPresented: $showSettings) {
                    if var cfg = config {
                        SettingsView(config: Binding(
                            get: { cfg },
                            set: { cfg = $0; config = $0 }
                        )) { showSettings = false }
                    }
                }
            } else {
                ConfigView { cfg in config = cfg }
            }
        }
        .preferredColorScheme(.dark)
    }
}

struct MainView: View {
    let config: VMConfig
    let onReconfigure: () -> Void
    let onSettings: () -> Void

    @State private var vramMB: Int = 0

    var body: some View {
        ZStack {
            Theme.canvas.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    specCard
                    startLink
                    secondaryActions
                }
                .padding(20)
            }
        }
        .navigationTitle(config.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { onSettings() } label: {
                    Image(systemName: "gearshape").foregroundColor(Theme.textMuted)
                }
            }
        }
        .onAppear { vramMB = DeviceProfile.estimatedVRAMMB(ramGB: Double(config.ramMB)/1024, cpuCores: config.cpuCount) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("虚拟机就绪").font(.system(size: 26, weight: .semibold))
                .foregroundColor(Theme.text)
            Text("点 Start 进入启动会话，进度和日志会实时显示")
                .font(.system(size: 12)).foregroundColor(Theme.textMuted)
        }
    }

    private var specCard: some View {
        VStack(spacing: 10) {
            SettingRow(icon: "memorychip.fill", title: "内存", iconColor: Theme.iconMemory) {
                HStack(spacing: 2) {
                    RollingNumber(value: String(format: "%.1f", Double(config.ramMB)/1024))
                    Text("GiB").font(.system(size: 11)).foregroundColor(Theme.textMuted)
                }
            }
            SettingRow(icon: "cpu.fill", title: "CPU 核心", iconColor: Theme.iconCPU) {
                RollingNumber(value: "\(config.cpuCount)")
            }
            SettingRow(icon: "rectangle.3.group.fill", title: "显存",
                       subtitle: vramMB < DeviceProfile.lowVRAMThresholdMB
                           ? "内存占用高，显存已被压缩"
                           : "与内存共享同一预算",
                       iconColor: vramMB < DeviceProfile.lowVRAMThresholdMB ? Theme.warn : Theme.iconVRAM) {
                HStack(spacing: 2) {
                    RollingNumber(value: "\(vramMB)",
                                  color: vramMB < DeviceProfile.lowVRAMThresholdMB ? Theme.warn : Theme.text)
                    Text("MB").font(.system(size: 11)).foregroundColor(Theme.textMuted)
                }
            }
            SettingRow(icon: "rectangle.on.rectangle.fill", title: "分辨率", iconColor: Theme.iconRes) {
                Text("\(config.width)×\(config.height)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Theme.textMuted)
            }
            SettingRow(icon: "ant.fill", title: "JIT",
                       subtitle: DebugCapability.jitAvailable
                           ? "已检测到调试权限"
                           : "未检测到调试权限，已禁用",
                       iconColor: (DebugCapability.jitAvailable && config.enableJIT)
                           ? Theme.iconJIT : Theme.textFaint) {
                Text(DebugCapability.jitAvailable ? (config.enableJIT ? "开" : "关") : "不可用")
                    .font(.system(size: 12))
                    .foregroundColor(DebugCapability.jitAvailable ? Theme.textMuted : Theme.warn)
            }
            .opacity(DebugCapability.jitAvailable ? 1 : 0.55)
        }
    }

    private var startLink: some View {
        NavigationLink {
            SessionView(config: config)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "play.fill")
                Text("Start").font(.system(size: 15, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .foregroundColor(Theme.canvas)
        }
        .nativeButton(prominent: true)
    }

    private var secondaryActions: some View {
        HStack(spacing: 12) {
            NavigationLink {
                DownloadsView()
            } label: {
                Label("下载", systemImage: "arrow.down.circle")
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .nativeButton()

            // Settings lives in the navigation-bar gear; this row is edit-config only.
            Button {
                onReconfigure()
            } label: {
                Label("编辑配置", systemImage: "slider.horizontal.3")
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }.nativeButton()
        }
    }
}
