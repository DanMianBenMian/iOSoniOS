import SwiftUI

/// The page shown after Start: live boot progress and raw engine log.
struct SessionView: View {
    let config: VMConfig

    @State private var entries: [RyLog.Entry] = []
    @State private var steps: [BootStep] = []
    @State private var finished = false
    @Environment(\.dismiss) private var dismiss

    struct BootStep: Identifiable {
        let id = UUID()
        let title: String
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
        ZStack {
            Theme.canvas.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    summaryCard
                    progressCard
                    logCard
                }
                .padding(20)
            }
        }
        .navigationTitle("启动会话")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if finished {
                    Button("完成") { dismiss() }.tint(Theme.accent)
                }
            }
        }
        .task {
            entries = RyLog.recent(200)
            await runSequence()
        }
    }

    private var summaryCard: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Theme.accentDim).frame(width: 42, height: 42)
                Image(systemName: finished ? "checkmark" : "bolt.horizontal.fill")
                    .font(.system(size: 18)).foregroundColor(Theme.accent)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(config.name).font(.system(size: 15, weight: .medium))
                    .foregroundColor(Theme.text)
                Text("\(config.ramMB/1024) GiB · \(config.cpuCount) 核 · 显存 \(DeviceProfile.estimatedVRAMMB(ramGB: Double(config.ramMB)/1024, cpuCores: config.cpuCount)) MB")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Theme.textMuted)
            }
            Spacer()
            Text(finished ? "就绪" : "启动中")
                .font(.system(size: 11)).foregroundColor(finished ? Theme.ok : Theme.textMuted)
        }
        .padding(14)
        .background(Theme.surface)
        .cornerRadius(12)
    }

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("启动步骤").font(.system(size: 13, weight: .medium))
                .foregroundColor(Theme.text)
            ForEach(steps) { step in
                HStack(spacing: 10) {
                    Image(systemName: icon(for: step.state))
                        .font(.system(size: 14))
                        .foregroundColor(color(for: step.state))
                        .frame(width: 18)
                    Text(step.title)
                        .font(.system(size: 12))
                        .foregroundColor(step.state == "等待" ? Theme.textFaint : Theme.text)
                    Spacer()
                    Text(step.state)
                        .font(.system(size: 10)).foregroundColor(Theme.textFaint)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(14)
        .background(Theme.surface)
        .cornerRadius(12)
    }

    private var logCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("实时日志").font(.system(size: 13, weight: .medium))
                    .foregroundColor(Theme.text)
                Spacer()
                Text("原文 · 每行存盘")
                    .font(.system(size: 10)).foregroundColor(Theme.textFaint)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(entries.suffix(250)) { e in
                            Text(rawLine(e))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(logColor(for: e.level))
                                .textSelection(.enabled)
                                .id(e.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 280, maxHeight: 420)
                .background(Theme.canvas.opacity(0.6))
                .cornerRadius(8)
                .onChange(of: entries.count) { _ in
                    if let last = entries.last {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(Theme.surface)
        .cornerRadius(12)
    }

    private func rawLine(_ e: RyLog.Entry) -> String {
        "[\(e.time)] \(e.level.uppercased()) \(e.tag): \(e.message)"
    }

    private func runSequence() async {
        steps = stepTitles.map { BootStep(title: $0) }

        await setStep(0, "进行中")
        RyLog.log("boot", "device=\(ProcessInfo.processInfo.machineName) ios=\(UIDevice.current.systemVersion)")
        try? await Task.sleep(nanoseconds: 120_000_000)
        await setStep(0, "完成")

        await setStep(1, "进行中")
        RyLog.ensureBundledAssets()
        let found = probeAssets()
        try? await Task.sleep(nanoseconds: 120_000_000)
        await setStep(1, found > 0 ? "完成" : "注意")

        await setStep(2, "进行中")
        let result = RyEngineSelfTest.run()
        try? await Task.sleep(nanoseconds: 120_000_000)
        await setStep(2, result.pagesMatch ? "完成" : "注意")

        await setStep(3, "进行中")
        try? await Task.sleep(nanoseconds: 120_000_000)
        await setStep(3, result.jitOK ? "完成" : "注意")

        await setStep(4, "进行中")
        RyLog.log("boot", "live log ready")
        try? await Task.sleep(nanoseconds: 120_000_000)
        await setStep(4, "完成")

        entries = RyLog.recent(200)
        finished = true
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
        withAnimation(.easeOut(duration: 0.25)) { steps = copy }
        entries = RyLog.recent(200)
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
        case "完成": return Theme.ok
        case "注意": return Theme.warn
        case "进行中": return Theme.accent
        default: return Theme.textFaint
        }
    }
    private func logColor(for level: String) -> Color {
        switch level {
        case "error": return Theme.logError
        case "warn": return Theme.logWarn
        case "guest": return Theme.logGuest
        default: return Theme.textMuted
        }
    }
}
