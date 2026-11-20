import SwiftUI

struct ContentView: View {
    @State private var tab = 0
    var body: some View {
        TabView(selection: $tab) {
            BootView().tabItem { Label("启动", systemImage: "power") }.tag(0)
            LogView().tabItem { Label("日志", systemImage: "doc.text.magnifyingglass") }.tag(1)
            AboutView().tabItem { Label("关于", systemImage: "info.circle") }.tag(2)
        }
    }
}

// MARK: - Boot view: plain-language status + live log, right on launch

struct BootView: View {
    @State private var entries: [RyLog.Entry] = []
    @State private var steps: [BootStep] = []
    @State private var booted = false

    struct BootStep: Identifiable {
        let id = UUID()
        let text: String
        var state: String = "等待"   // 等待 / 进行中 / 完成 / 注意
    }

    private let stepsDef = [
        "读取设备与系统信息",
        "检查固件资产",
        "检测内存页大小",
        "测试可执行内存（JIT）",
        "打开实时日志"
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    statusCard
                    liveLogCard
                }
                .padding()
            }
            .navigationTitle("iOSoniOS · 启动")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("重跑") { Task { await runBoot() } }
                }
            }
            .task { if !booted { await runBoot() } }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("在 iPad 里运行 iOS").font(.title2.weight(.semibold))
            Text("这是第一阶段：先把虚拟机的引擎和启动链跑通，还看不到桌面。")
                .font(.subheadline).foregroundColor(.secondary)
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("启动进度").font(.headline)
            ForEach(Array(steps.enumerated()), id: \.element.id) { i, step in
                HStack(spacing: 10) {
                    Image(systemName: icon(for: step.state))
                        .foregroundColor(color(for: step.state))
                        .frame(width: 20)
                    Text("\(i + 1). \(step.text)")
                        .font(.body)
                    Spacer()
                    Text(step.state).font(.caption).foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var liveLogCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("实时日志").font(.headline)
                Spacer()
                Text("每行立即存盘").font(.caption).foregroundColor(.secondary)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(entries.suffix(120)) { e in
                            HStack(alignment: .top, spacing: 6) {
                                Text(e.time).font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.secondary)
                                Text(e.message)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(logColor(for: e.level))
                                    .textSelection(.enabled)
                            }
                            .id(e.id)
                        }
                    }
                }
                .frame(height: 260)
                .onChange(of: entries.count) { _ in
                    if let last = entries.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Boot sequence, one step at a time with human-readable narration

    private func runBoot() async {
        booted = true
        steps = stepsDef.map { BootStep(text: $0) }
        entries = RyLog.recent(200)

        await setStep(0, "进行中")
        say("你好，我是这台虚拟 iOS 的启动助手。下面每一步我都会用大白话告诉你发生了什么。")
        say("设备是 \(ProcessInfo.processInfo.machineName)，系统 \(UIDevice.current.systemVersion)。")
        await setStep(0, "完成")

        await setStep(1, "进行中")
        let assets = probeAssets()
        if assets == 0 {
            say("注意：还没找到内核和设备树文件。界面能正常用，但还启动不了虚拟系统。")
            await setStep(1, "注意")
        } else {
            say("找到 \(assets) 个固件文件，启动材料就绪。")
            await setStep(1, "完成")
        }

        await setStep(2, "进行中")
        let result = RyEngineSelfTest.run()
        if result.pagesMatch {
            say("内存页大小是 16384 字节，和 iOS 内核一致，可以直接映射，不用改内核。")
            await setStep(2, "完成")
        } else {
            say("注意：内存页大小不是 16384，后面要改内核才能跑。")
            await setStep(2, "注意")
        }

        await setStep(3, "进行中")
        if result.jitOK {
            say("好消息：可执行内存测试通过，这个 App 可以运行 JIT，虚拟机速度有保证。")
            await setStep(3, "完成")
        } else {
            say(result.detail)
            say("这说明当前签名不允许运行动态生成的代码。别担心，第一阶段只是自检，不影响看日志；真正跑内核时需要换成开发者签名并附加调试器。")
            await setStep(3, "注意")
        }

        await setStep(4, "进行中")
        say("实时日志已经打开，下面所有底层输出都会一边显示一边存到文件里。")
        await setStep(4, "完成")

        // start live refresh after the boot narration completes
        Task {
            while true {
                entries = RyLog.recent(200)
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }
    }

    private func setStep(_ index: Int, _ state: String) async {
        guard index < steps.count else { return }
        var copy = steps
        copy[index].state = state
        steps = copy
        try? await Task.sleep(nanoseconds: 120_000_000)
    }

    private func say(_ text: String) {
        RyLog.log("启动", text, level: .info)
        entries = RyLog.recent(200)
    }

    private func probeAssets() -> Int {
        let fm = FileManager.default
        let docs = RyLog.documentsURL
        let needed = ["bootkc", "dtree", "ramdisk.dmg", "trustcache", "nvram.bin"]
        let found = needed.filter { fm.fileExists(atPath: docs.appendingPathComponent($0).path) }
        RyLog.log("资产", "Documents 里找到 \(found.count)/\(needed.count) 个：\(found.joined(separator: ", "))")
        // Give the app a chance to copy bundled assets in on first launch.
        RyLog.ensureBundledAssets()
        let after = needed.filter { fm.fileExists(atPath: docs.appendingPathComponent($0).path) }
        return after.count
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

struct AboutView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("我们在做什么").font(.title3.weight(.semibold))
                Text("""
                目标：在 iPad 的一个 App 里，用软件模拟出一台苹果电脑需要的硬件，
                然后让真正的 iOS 内核在里面启动起来。

                第一步（已完成）：从固件里取出 A14 的内核和设备树，改好设备树。
                第二步（当前）：在 App 里把 JIT 引擎跑起来，确认能执行代码。
                第三步：把内核喂进去，追到第一行串口输出。
                后面才是画面、触控、桌面。

                所有日志每一行都会立刻写到文件，崩溃也不会丢。
                """)
                .font(.system(.body, design: .monospaced))

                Text("参考资料").font(.title3.weight(.semibold))
                Link("darwin-vm", destination: URL(string: "https://github.com/jprx/darwin-vm")!)
                Link("Henge", destination: URL(string: "https://github.com/Leviidev/Henge")!)
                Link("UniXNU", destination: URL(string: "https://github.com/UniXNU/UniXNU")!)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .navigationTitle("关于")
    }
}
