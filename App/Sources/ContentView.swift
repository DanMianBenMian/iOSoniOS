import SwiftUI

struct ContentView: View {
    @State private var config: VMConfig? = VMConfig.load()
    @State private var showConfig = false
    @State private var showSettings = false
    @State private var bootVM: VMConfig?

    var body: some View {
        Group {
            if let cfg = config {
                NavigationStack {
                    MainView(config: cfg,
                             onReconfigure: { showConfig = true },
                             onSettings: { showSettings = true },
                             onStart: { bootVM = cfg })
                    .navigationDestination(isPresented: Binding(
                        get: { bootVM != nil },
                        set: { if !$0 { bootVM = nil } }
                    )) {
                        if let vm = bootVM { VMView(config: vm) }
                    }
                }
                .sheet(isPresented: $showConfig) {
                    ConfigView(config: cfg) { newConfig in
                        showConfig = false
                        config = newConfig
                    }
                }
                .sheet(isPresented: $showSettings) {
                    SettingsView(config: Binding(
                        get: { cfg },
                        set: { config = $0 }
                    )) { showSettings = false }
                }
            } else {
                ConfigView { config = $0 }
            }
        }
        .preferredColorScheme(.light)
    }
}

struct MainView: View {
    let config: VMConfig
    let onReconfigure: () -> Void
    let onSettings: () -> Void
    let onStart: () -> Void

    @State private var vramMB: Int = 0

    private var vramLow: Bool { vramMB < DeviceProfile.lowVRAMThresholdMB }

    var body: some View {
        ZStack {
            Theme.canvas.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    specCard
                    startButton
                    secondaryActions
                }
                .padding(20)
            }
        }
        .navigationTitle(config.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { onSettings() } label: {
                    Image(systemName: "gearshape").foregroundColor(Theme.textMuted)
                }
            }
        }
        .onAppear {
            vramMB = DeviceProfile.estimatedVRAMMB(ramGB: Double(config.ramMB) / 1024,
                                                   cpuCores: config.cpuCount)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(config.name).font(.system(size: 28, weight: .semibold))
                .foregroundColor(Theme.text)
            Text("\(config.ramMB / 1024) GiB · \(config.cpuCount) 核 · 显存 \(vramMB) MB")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(Theme.textMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var specCard: some View {
        VStack(spacing: 10) {
            SettingRow(icon: "memorychip.fill", title: "内存", iconColor: Theme.iconMemory) {
                Text("\(config.ramMB / 1024) GiB")
                    .font(.system(size: 13, design: .monospaced)).foregroundColor(Theme.textMuted)
            }
            SettingRow(icon: "cpu.fill", title: "CPU 核心", iconColor: Theme.iconCPU) {
                Text("\(config.cpuCount)")
                    .font(.system(size: 13, design: .monospaced)).foregroundColor(Theme.textMuted)
            }
            SettingRow(icon: "rectangle.3.group.fill", title: "显存",
                       iconColor: vramLow ? Theme.warn : Theme.iconVRAM) {
                Text("\(vramMB) MB")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(vramLow ? Theme.warn : Theme.textMuted)
            }
            SettingRow(icon: "rectangle.on.rectangle.fill", title: "分辨率", iconColor: Theme.iconRes) {
                Text("\(config.width)×\(config.height)")
                    .font(.system(size: 12, design: .monospaced)).foregroundColor(Theme.textMuted)
            }
            SettingRow(icon: "ant.fill", title: "JIT",
                       subtitle: DebugCapability.jitAvailable ? nil : "无调试权限",
                       iconColor: (DebugCapability.jitAvailable && config.enableJIT)
                           ? Theme.iconJIT : Theme.textFaint) {
                Text(DebugCapability.jitAvailable ? (config.enableJIT ? "开" : "关") : "不可用")
                    .font(.system(size: 12))
                    .foregroundColor(DebugCapability.jitAvailable ? Theme.textMuted : Theme.warn)
            }
            .opacity(DebugCapability.jitAvailable ? 1 : 0.6)
        }
    }

    private var startButton: some View {
        Button(action: onStart) {
            HStack(spacing: 8) {
                Image(systemName: "play.fill")
                Text("Start").font(.system(size: 16, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
        }
        .nativeButton(prominent: true)
    }

    private var secondaryActions: some View {
        HStack(spacing: 12) {
            NavigationLink {
                DownloadsView()
            } label: {
                Label("固件", systemImage: "arrow.down.circle")
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
            }.nativeButton()

            Button(action: onReconfigure) {
                Label("配置", systemImage: "slider.horizontal.3")
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
            }.nativeButton()
        }
    }
}
