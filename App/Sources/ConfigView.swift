import SwiftUI

struct ConfigView: View {
    @State private var config: VMConfig
    let onCreate: (VMConfig) -> Void

    private let ramTiers = DeviceProfile.memoryTiersGB
    private let coreTiers = Array(1...max(2, min(8, DeviceProfile.physicalCores)))

    @State private var ramIndex: Int
    @State private var coreIndex: Int
    @State private var showFirmwarePrompt = false

    init(config: VMConfig = VMConfig.defaults, onCreate: @escaping (VMConfig) -> Void) {
        self._config = State(initialValue: config)
        self.onCreate = onCreate
        let tiers = DeviceProfile.memoryTiersGB
        let nearest = tiers.indices.min {
            abs(tiers[$0] * 1024 - Double(config.ramMB)) < abs(tiers[$1] * 1024 - Double(config.ramMB))
        } ?? 0
        self._ramIndex = State(initialValue: nearest)
        let cores = Array(1...max(2, min(8, DeviceProfile.physicalCores)))
        self._coreIndex = State(initialValue: max(0, cores.firstIndex(of: config.cpuCount) ?? 0))
    }

    private var ramGB: Double { ramTiers[min(ramIndex, ramTiers.count - 1)] }
    private var cores: Int { coreTiers[min(coreIndex, coreTiers.count - 1)] }
    private var vramMB: Int { DeviceProfile.estimatedVRAMMB(ramGB: ramGB, cpuCores: cores) }
    private var vramLow: Bool { vramMB < DeviceProfile.lowVRAMThresholdMB }

    private var jetsamWarning: String? {
        let ceiling = DeviceProfile.jetsamCeilingGB
        guard ramGB >= ceiling else { return nil }
        let total = DeviceProfile.totalRAMGB
        return "设备可用内存约 \(Int(total)) GiB，分 \(Int(ramGB)) GiB 给虚拟机可能触发系统杀进程（jetsam）。建议 \(String(format: "%.1f", max(1, ceiling - 0.5))) GiB 以下。"
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.canvas.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 16) {
                        header
                        nameCard
                        ramCard
                        if let w = jetsamWarning { warningCard(w) }
                        cpuCard
                        vramCard
                        displayCard
                        advancedCard
                        firmwareCard
                    }
                    .padding(20)
                }
            }
            .navigationTitle("配置虚拟机")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        attemptCreate()
                    } label: {
                        Image(systemName: "checkmark")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .tint(Theme.accent)
                    .accessibilityLabel("创建虚拟机")
                }
            }
            .confirmationDialog("还没有导入固件", isPresented: $showFirmwarePrompt, titleVisibility: .visible) {
                Button("跳过，先创建（测试版）") { finishCreate() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("没有 IPSW 就无法真正启动内核。测试阶段可以跳过，先体验界面和流程。")
            }
        }
        .onChange(of: ramIndex) { _ in sync() }
        .onChange(of: coreIndex) { _ in sync() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("新建虚拟机").font(.system(size: 26, weight: .semibold))
                .foregroundColor(Theme.text)
            Text("填好后点右上角 ✓ 创建")
                .font(.system(size: 12)).foregroundColor(Theme.textMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var nameCard: some View {
        SettingRow(icon: "tag.fill", title: "名称", subtitle: "给这台虚拟机起个名字",
                   iconColor: Theme.iconName) {
            TextField("我的 iOS", text: $config.name)
                .font(.system(size: 13))
                .foregroundColor(Theme.text)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 160)
        }
    }

    private var ramCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingRow(icon: "memorychip.fill", title: "内存", subtitle: "分配给 guest 的运行内存",
                       iconColor: Theme.iconMemory) {
                HStack(spacing: 2) {
                    RollingNumber(value: String(format: "%.1f", ramGB),
                                  color: jetsamWarning == nil ? Theme.text : Theme.warn)
                    Text("GiB").font(.system(size: 11)).foregroundColor(Theme.textMuted)
                }
            }
            TierSlider(tiers: ramTiers, index: $ramIndex,
                       label: { String(format: "%.1f G", $0) },
                       tint: jetsamWarning == nil ? Theme.accent : Theme.warn)
                .padding(.horizontal, 14)
                .padding(.bottom, 6)
        }
        .background(Theme.surface)
        .cornerRadius(12)
    }

    private func warningCard(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13)).foregroundColor(Theme.warn)
            Text(text).font(.system(size: 11))
                .foregroundColor(Theme.warn.opacity(0.92))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Theme.warn.opacity(0.09))
        .cornerRadius(10)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private var cpuCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingRow(icon: "cpu.fill", title: "CPU 核心",
                       subtitle: "本机 \(DeviceProfile.physicalCores) 核，guest 用 \(cores) 核",
                       iconColor: Theme.iconCPU) {
                RollingNumber(value: "\(cores)")
            }
            TierSlider(tiers: coreTiers.map(Double.init), index: $coreIndex,
                       label: { "\(Int($0)) 核" })
                .padding(.horizontal, 14)
                .padding(.bottom, 6)
        }
        .background(Theme.surface)
        .cornerRadius(12)
    }

    private var vramCard: some View {
        SettingRow(icon: "rectangle.3.group.fill", title: "显存",
                   subtitle: "与内存共享预算，内存越高显存越低",
                   iconColor: vramLow ? Theme.warn : Theme.iconVRAM) {
            HStack(spacing: 4) {
                RollingNumber(value: "\(vramMB)", color: vramLow ? Theme.warn : Theme.text)
                Text("MB").font(.system(size: 11)).foregroundColor(Theme.textMuted)
            }
        }
    }

    private var displayCard: some View {
        VStack(spacing: 10) {
            SettingRow(icon: "rectangle.on.rectangle.fill", title: "分辨率",
                       subtitle: "guest 屏幕尺寸", iconColor: Theme.iconRes) {
                Picker("", selection: Binding(
                    get: { Resolution(width: config.width, height: config.height) },
                    set: { config.width = $0.width; config.height = $0.height }
                )) {
                    ForEach(Resolution.all) { r in
                        Text("\(r.width)×\(r.height)").tag(r)
                    }
                }
                .pickerStyle(.menu)
                .tint(Theme.accent)
                .frame(maxWidth: 150)
            }
            SettingRow(icon: "display", title: "图形显示",
                       subtitle: "是否启用虚拟屏幕", iconColor: Theme.iconDisplay) {
                Toggle("", isOn: $config.enableDisplay).labelsHidden().tint(Theme.accent)
            }
        }
    }

    private var advancedCard: some View {
        SettingRow(icon: "terminal.fill", title: "启动参数",
                   subtitle: "传给内核的 boot-args", iconColor: Theme.iconBoot) {
            TextField("-v", text: $config.bootArgs)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Theme.text)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 170)
        }
    }

    private var firmwareCard: some View {
        SettingRow(icon: "shippingbox.fill", title: "固件",
                   subtitle: existingIPSW() != nil
                       ? "已放入 \(existingIPSW() ?? "")"
                       : "创建前需要导入 IPSW（测试版可跳过）",
                   iconColor: Theme.iconFirmware) {
            NavigationLink {
                DownloadsView()
            } label: {
                Text("前往下载")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.accent)
            }
            .buttonStyle(.plain)
        }
    }

    private func attemptCreate() {
        sync()
        config.save()
        if existingIPSW() != nil {
            finishCreate()
        } else {
            showFirmwarePrompt = true
        }
    }

    private func finishCreate() {
        onCreate(config)
    }

    private func existingIPSW() -> String? {
        let docs = RyLog.documentsURL
        let names = (try? FileManager.default.contentsOfDirectory(atPath: docs.path)) ?? []
        return names.first { $0.hasSuffix(".ipsw") }
    }

    private func sync() {
        config.ramMB = Int((ramGB * 1024).rounded())
        config.cpuCount = cores
    }
}

struct Resolution: Hashable, Identifiable {
    let width: Int
    let height: Int
    var id: String { "\(width)x\(height)" }

    static let all = [
        Resolution(width: 1170, height: 2532),
        Resolution(width: 834, height: 1194),
        Resolution(width: 1080, height: 1920),
        Resolution(width: 768, height: 1024),
    ]
}
