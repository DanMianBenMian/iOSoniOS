import SwiftUI

struct ConfigView: View {
    @State private var config: VMConfig
    let onCreate: (VMConfig) -> Void

    private let ramTiers = DeviceProfile.memoryTiersGB
    private let coreTiers = Array(1...max(2, min(8, DeviceProfile.physicalCores)))

    @State private var ramIndex: Int
    @State private var coreIndex: Int

    init(config: VMConfig = VMConfig.defaults, onCreate: @escaping (VMConfig) -> Void) {
        self._config = State(initialValue: config)
        self.onCreate = onCreate
        let tiers = DeviceProfile.memoryTiersGB
        let nearest = tiers.indices.min { abs(tiers[$0] * 1024 - Double(config.ramMB)) < abs(tiers[$1] * 1024 - Double(config.ramMB)) } ?? 0
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
        return "设备可用内存约 \(Int(total)) GiB，分 \(Int(ramGB)) GiB 给虚拟机可能触发系统杀进程（jetsam）。建议降到 \(String(format: "%.1f", max(1, ceiling - 0.5))) GiB 以下。"
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.canvas.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 18) {
                        header
                        nameCard
                        ramCard
                        if let warning = jetsamWarning { warningCard(warning) }
                        cpuCard
                        vramCard
                        displayCard
                        advancedCard
                        createButton
                    }
                    .padding(20)
                }
            }
            .navigationTitle("配置虚拟机")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .onChange(of: ramIndex) { _ in sync() }
        .onChange(of: coreIndex) { _ in sync() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("新建虚拟机").font(.system(size: 26, weight: .semibold))
                    .foregroundColor(Theme.text)
                Text("参数决定它能跑多稳，创建后仍可修改")
                    .font(.system(size: 12)).foregroundColor(Theme.textMuted)
            }
            Spacer()
        }
    }

    private var nameCard: some View {
        SettingRow(icon: "tag", title: "名称", subtitle: "给这台虚拟机起个名字") {
            TextField("我的 iOS", text: $config.name)
                .font(.system(size: 13))
                .foregroundColor(Theme.text)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 160)
        }
    }

    private var ramCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingRow(icon: "memorychip", title: "内存", subtitle: "分配给 guest 的运行内存") {
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
        }
        .padding(.vertical, 6)
        .background(Theme.surface)
        .cornerRadius(12)
    }

    private func warningCard(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14)).foregroundColor(Theme.warn)
            Text(text)
                .font(.system(size: 11))
                .foregroundColor(Theme.warn.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Theme.warn.opacity(0.09))
        .cornerRadius(10)
        .transition(.opacity.combined(with: .move(edge: .top)))
        .animation(.easeOut(duration: 0.25), value: jetsamWarning)
    }

    private var cpuCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingRow(icon: "cpu", title: "CPU 核心",
                       subtitle: "本机 \(DeviceProfile.physicalCores) 核，guest 用 \(cores) 核") {
                RollingNumber(value: "\(cores)", color: Theme.text)
            }
            TierSlider(tiers: coreTiers.map(Double.init), index: $coreIndex,
                       label: { "\(Int($0)) 核" })
                .padding(.horizontal, 14)
        }
        .padding(.vertical, 6)
        .background(Theme.surface)
        .cornerRadius(12)
    }

    private var vramCard: some View {
        SettingRow(icon: "rectangle.3.group", title: "显存",
                   subtitle: "按内存 / 核心 / 机型估算",
                   iconColor: vramLow ? Theme.warn : Theme.accent) {
            HStack(spacing: 4) {
                RollingNumber(value: "\(vramMB)", color: vramLow ? Theme.warn : Theme.text)
                Text("MB").font(.system(size: 11)).foregroundColor(Theme.textMuted)
            }
        }
    }

    private var displayCard: some View {
        VStack(spacing: 10) {
            SettingRow(icon: "rectangle.on.rectangle", title: "分辨率", subtitle: "guest 屏幕尺寸") {
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
            SettingRow(icon: "display", title: "图形显示", subtitle: "是否启用虚拟屏幕") {
                Toggle("", isOn: $config.enableDisplay).labelsHidden().tint(Theme.accent)
            }
        }
    }

    private var advancedCard: some View {
        SettingRow(icon: "terminal", title: "启动参数", subtitle: "传给内核的 boot-args") {
            TextField("-v", text: $config.bootArgs)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Theme.text)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 170)
        }
    }

    private var createButton: some View {
        Button {
            sync()
            config.save()
            onCreate(config)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill")
                Text("创建虚拟机").font(.system(size: 15, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
        }
        .buttonStyle(.plain)
        .foregroundColor(Theme.canvas)
        .background(Theme.accent)
        .cornerRadius(12)
        .padding(.top, 4)
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
