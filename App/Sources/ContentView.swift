import SwiftUI

struct ContentView: View {
    @State private var config: VMConfig? = VMConfig.load()
    @State private var showConfig = false

    var body: some View {
        Group {
            if let cfg = config {
                MainView(config: cfg,
                         onReconfigure: { showConfig = true },
                         onDelete: {
                             VMConfig.clear()
                             config = nil
                         })
                .sheet(isPresented: $showConfig) {
                    ConfigView(config: cfg) { newConfig in
                        showConfig = false
                        config = newConfig
                    }
                }
            } else {
                ConfigView { cfg in
                    config = cfg
                }
            }
        }
    }
}

// MARK: - Main view: Start button, human-language card titles, raw log output

struct MainView: View {
    let config: VMConfig
    let onReconfigure: () -> Void
    let onDelete: () -> Void

    @State private var entries: [RyLog.Entry] = []
    @State private var running = false
    @State private var steps: [BootStep] = []
    @State private var refreshTask: Task<Void, Never>?

    struct BootStep: Identifiable {
        let id = UUID()
        let title: String        // human-language, shown in card header
        var state: String = "等待"
    }

    private let stepTitles = [
        "正在读取设备与系统信息",
        "正在检查固件资产",
        "正在检测内存页大小",
        "正在探测可执行内存",
        "正在打开实时日志",
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    configCard
                    controlsCard
                    if !steps.isEmpty { progressCard }
                    logCard
                }
                .padding()
            }
            .navigationTitle(config.name)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("修改配置", action: onReconfigure)
                        Button("删除虚拟机", role: .destructive, action: onDelete)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .task {
                entries = RyLog.recent(200)
                startLiveRefresh()
            }
            .onDisappear { refreshTask?.cancel() }
        }
    }

    private var configCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("虚拟机配置", systemImage: "slider.horizontal.3")
                .font(.headline)
            HStack { Text("内存"); Spacer(); Text("\(config.ramMB) MB").monospaced() }
            HStack { Text("CPU"); Spacer(); Text("\(config.cpuCount) 核心").monospaced() }
            HStack { Text("分辨率"); Spacer(); Text("\(config.width) × \(config.height)").monospaced() }
            HStack { Text("JIT"); Spacer(); Text(config.enableJIT ? "开启" : "关闭").monospaced() }
            HStack { Text("启动参数"); Spacer(); Text(config.bootArgs).monospaced() }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var controlsCard: some View {
        VStack(spacing: 10) {
            HStack {
                Image(systemName: running ? "bolt.horizontal.fill" : "play.circle.fill")
                    .font(.title2)
                Text(running ? "正在启动…" : "准备就绪")
                    .font(.headline)
                Spacer()
            }
            Button {
                if !running { Task { await runSequence() } }
            } label: {
                Label("Start", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(running)

            Text("点 Start 才会运行。启动过程会在下面显示，日志在最后一段实时滚动。")
                .font(.caption).foregroundColor(.secondary)
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("启动步骤").font(.headline)
            ForEach(Array(steps.enumerated()), id: \.element.id) { i, step in
                HStack(spacing: 10) {
                    Image(systemName: icon(for: step.state))
                        .foregroundColor(color(for: step.state))
                        .frame(width: 20)
                    Text(step.title)     // human-language title here, not in log
                        .font(.body)
                    Spacer()
                    Text(step.state).font(.caption).foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var logCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("实时日志（原文）").font(.headline)
                Spacer()
                Text("每行立即存盘").font(.caption).foregroundColor(.secondary)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(entries.suffix(200)) { e in
                            Text(rawLine(e))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(logColor(for: e.level))
                                .textSelection(.enabled)
                                .id(e.id)
                        }
                    }
                }
                .frame(minHeight: 220, maxHeight: 320)
                .onChange(of: entries.count) { _ in
                    if let last = entries.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    // Raw log format, identical to what lands in iosonios.log.
    private func rawLine(_ e: RyLog.Entry) -> String {
        "[\(e.time)] \(e.level.uppercased()) \(e.tag): \(e.message)"
    }

    private func startLiveRefresh() {
        refreshTask?.cancel()
        refreshTask = Task {
            while !Task.isCancelled {
                entries = RyLog.recent(200)
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }
    }

    private func runSequence() async {
        running = true
        steps = stepTitles.map { BootStep(title: $0) }
        entries = RyLog.recent(200)

        await setStep(0, "进行中")
        RyLog.log("boot", "device=\(ProcessInfo.processInfo.machineName) ios=\(UIDevice.current.systemVersion)")
        await setStep(0, "完成")

        await setStep(1, "进行中")
        RyLog.ensureBundledAssets()
        let count = probeAssets()
        await setStep(1, count > 0 ? "完成" : "注意")

        await setStep(2, "进行中")
        let result = RyEngineSelfTest.run()
        await setStep(2, result.pagesMatch ? "完成" : "注意")

        await setStep(3, "进行中")
        await setStep(3, result.jitOK ? "完成" : "注意")

        await setStep(4, "进行中")
        RyLog.log("boot", "live log ready")
        await setStep(4, "完成")

        running = false
    }

    private func probeAssets() -> Int {
        let fm = FileManager.default
        let docs = RyLog.documentsURL
        let needed = ["bootkc", "dtree", "ramdisk.dmg", "trustcache", "nvram.bin"]
        let found = needed.filter { fm.fileExists(atPath: docs.appendingPathComponent($0).path) }
        RyLog.log("assets", "found \(found.count)/\(needed.count): \(found.joined(separator: ", "))")
        return found.count
    }

    private func setStep(_ index: Int, _ state: String) async {
        guard index < steps.count else { return }
        var copy = steps
        copy[index].state = state
        steps = copy
        try? await Task.sleep(nanoseconds: 120_000_000)
    }

    private func icon(for state: String) -> String {
        switch state {
        case "完成": return "checkmark.circle.fill"
        case "注意": return "exclamationmark.triangle.fill"
        case "进行中": return "circle.circle.fill"
        default: return "circle"
        }
    }

    private func color(for state: String) -> Color {
        switch state {
        case "完成": return .green
        case "注意": return .orange
        case "进行中": return .accentColor
        default: return .secondary
        }
    }

    private func logColor(for level: String) -> Color {
        switch level {
        case "error": return .red
        case "warn": return .orange
        case "guest": return .purple
        default: return .primary
        }
    }
}
