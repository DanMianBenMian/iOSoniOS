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
            SettingRow(icon: "memorychip", title: "内存") {
                HStack(spacing: 2) {
                    RollingNumber(value: String(format: "%.1f", Double(config.ramMB)/1024))
                    Text("GiB").font(.system(size: 11)).foregroundColor(Theme.textMuted)
                }
            }
            SettingRow(icon: "cpu", title: "CPU 核心") {
                RollingNumber(value: "\(config.cpuCount)")
            }
            SettingRow(icon: "rectangle.3.group", title: "显存",
                       iconColor: vramMB < DeviceProfile.lowVRAMThresholdMB ? Theme.warn : Theme.accent) {
                HStack(spacing: 2) {
                    RollingNumber(value: "\(vramMB)",
                                  color: vramMB < DeviceProfile.lowVRAMThresholdMB ? Theme.warn : Theme.text)
                    Text("MB").font(.system(size: 11)).foregroundColor(Theme.textMuted)
                }
            }
            SettingRow(icon: "rectangle.on.rectangle", title: "分辨率") {
                Text("\(config.width)×\(config.height)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Theme.textMuted)
            }
            SettingRow(icon: "ant", title: "JIT",
                       subtitle: config.enableJIT ? "已开启（调试器授予后生效）" : "已关闭",
                       iconColor: config.enableJIT ? Theme.accent : Theme.textFaint) {
                Text(config.enableJIT ? "开" : "关")
                    .font(.system(size: 12)).foregroundColor(Theme.textMuted)
            }
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
            .background(Theme.accent)
            .foregroundColor(Theme.canvas)
            .cornerRadius(12)
        }
        .buttonStyle(.plain)
    }

    private var secondaryActions: some View {
        HStack(spacing: 12) {
            Button {
                onReconfigure()
            } label: {
                Label("修改配置", systemImage: "slider.horizontal.3")
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Theme.surface)
                    .foregroundColor(Theme.text)
                    .cornerRadius(10)
            }.buttonStyle(.plain)

            Button {
                onSettings()
            } label: {
                Label("设置", systemImage: "gearshape")
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Theme.surface)
                    .foregroundColor(Theme.text)
                    .cornerRadius(10)
            }.buttonStyle(.plain)
        }
    }
}
