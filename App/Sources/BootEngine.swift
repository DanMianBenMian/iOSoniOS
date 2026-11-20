import Foundation
import Darwin

/// Real boot work, now exposed as structured progress for the on-screen GUI.
///
/// Every stage of `run()` flips a `BootStep` state, which drives both the
/// percentage and the step chain in VMView. Failures raise a `BootIssue`
/// (icon + title + plain-language explanation) that the GUI renders as a card.
/// Nothing here is a fake animation: the states track actual work.
@MainActor
final class BootEngine: ObservableObject {

    struct Line: Identifiable {
        let id = UUID()
        let text: String
        let kind: Kind
        enum Kind { case info, ok, warn, error, guest }
    }

    /// One stage of the boot chain.
    struct BootStep: Identifiable, Equatable {
        let id: Int
        let icon: String
        let title: String
        var state: State = .pending
        enum State: Equatable { case pending, running, done, failed, skipped }
    }

    /// A GUI-displayable problem: icon, short title, plain-language detail.
    struct BootIssue: Identifiable {
        let id = UUID()
        let icon: String
        let title: String
        let detail: String
        let fatal: Bool
    }

    @Published private(set) var lines: [Line] = []
    @Published private(set) var running = false
    @Published private(set) var stage = "待机"
    @Published private(set) var reachedKernel = false

    // MARK: Progress surface
    @Published private(set) var steps: [BootStep] = []
    @Published private(set) var progress: Double = 0        // 0...1
    @Published private(set) var issue: BootIssue? = nil

    private var guestRAMSize = 0
    private var engineReady = false
    private var engineBackend: Int32 = 0

    private let ramMB: Int
    private let cpuCount: Int
    private let bootArgs: String

    init(config: VMConfig) {
        self.ramMB = max(512, config.ramMB)
        self.cpuCount = max(1, config.cpuCount)
        self.bootArgs = config.bootArgs
        self.steps = [
            BootStep(id: 0, icon: "cpu.fill",                   title: "引擎初始化"),
            BootStep(id: 1, icon: "bolt.fill",                  title: "指令自测"),
            BootStep(id: 2, icon: "shippingbox.fill",           title: "固件内核"),
            BootStep(id: 3, icon: "network",                    title: "设备树"),
            BootStep(id: 4, icon: "doc.text.magnifyingglass",   title: "内核解析"),
            BootStep(id: 5, icon: "play.fill",                  title: "内核执行"),
        ]
    }

    // MARK: - Lifecycle

    func start() {
        guard !running else { return }
        issue = nil
        resetSteps()
        running = true
        Task { await run() }
    }

    func shutdown() {
        ry_engine_shutdown()
        engineReady = false
        running = false
        stage = "已停止"
        append("引擎已释放", .info)
    }

    /// Hide the current error card (user dismissed it).
    func dismissIssue() { issue = nil }

    /// A hardware key arrived from the floating key pad.
    func noteKey(_ name: String) {
        append("key \(name) 已接收（内核未运行，暂未投递）", .guest)
    }

    // MARK: - Boot sequence

    private func run() async {
        append("iOSoniOS 启动序列", .info)
        append("设备 \(DeviceProfile.chipName) · guest \(ramMB) MiB / \(cpuCount) 核", .info)
        append("boot-args: \(bootArgs)", .info)

        // 1 — engine
        beginStep(0)
        await tick()
        guard await reserveGuestRAM() else {
            endStep(0, .failed)
            report(icon: "xmark.octagon.fill", title: "引擎启动失败",
                   detail: "无法为客机申请 \(ramMB) MiB 内存或初始化执行后端。试着把内存调低一点，或重启本 App 再试。",
                   fatal: true)
            return finish()
        }
        endStep(0)

        // 2 — self test
        beginStep(1)
        await tick()
        let testOK = await runEngineSelfTest()
        endStep(1, testOK ? .done : .failed)

        // 3 — kernel image
        beginStep(2)
        await tick()
        guard let kernel = await loadKernel() else {
            endStep(2, .failed)
            report(icon: "doc.badge.exclamationmark", title: "缺少内核文件",
                   detail: "找不到 bootkc（kernelcache）。请到「下载」页导入 IPSW，点「从 IPSW 提取内核」生成它；或手动把 bootkc 放进本 App 的文件目录。内核没就绪，虚拟机无法启动。",
                   fatal: true)
            return finish()
        }
        endStep(2)

        // 4 — device tree
        beginStep(3)
        await tick()
        let dtreeSize = await loadDeviceTree()
        endStep(3, dtreeSize > 0 ? .done : .skipped)

        // 5 — Mach-O parse
        beginStep(4)
        await tick()
        await parseKernel(kernel)
        endStep(4)

        // 6 — execute
        beginStep(5)
        await tick()
        let execOK = await runKernel(kernel)
        endStep(5, execOK ? .done : .failed)

        finish()
    }

    private func finish() {
        stage = "已停止"
        running = false
        append("—— 启动流程结束 ——", .info)
    }

    /// Loads the kernelcache into guest RAM and starts executing it.
    /// Returns false only for a real failure (not the instruction-budget stop).
    private func runKernel(_ kernel: Data) async -> Bool {
        // Route guest UART output into the app log, so kernel printk shows up.
        ry_engine_set_uart { ch in
            BootEngine.uartSink(ch)
        }
        var status = RyEngineStatus()
        let rc = kernel.withUnsafeBytes { raw -> Int32 in
            guard let base = raw.baseAddress else { return -1 }
            // 8M instructions is about a second of interpreter time.
            return ry_engine_boot_kernel(base, UInt64(kernel.count), 8_000_000, &status)
        }
        let detail = String(cString: ry_engine_detail(&status))
        if rc == 0 {
            append("内核已运行：\(detail)", .ok)
            return true
        }
        if rc == -4 {
            // RY_ERR_LIMIT — instruction budget exhausted, expected for the demo.
            append("内核执行停止 (rc=\(rc))：\(detail)", .info)
            return true
        }
        append("内核执行中断 (rc=\(rc))：\(detail)", .warn)
        report(icon: "exclamationmark.triangle.fill", title: "内核执行中断",
               detail: "解释器在第 \(status.stage) 步停下：\(detail)。这是软件模拟的已知限制，不代表客机损坏。可查看下方日志了解详情。",
               fatal: false)
        return false
    }

    /// UART sink: accumulate bytes into lines and emit them as guest log lines.
    private static var uartBuffer = ""
    fileprivate static func uartSink(_ ch: CChar) {
        let scalar = UnicodeScalar(UInt8(bitPattern: ch))
        if scalar == "\n" {
            let line = uartBuffer
            uartBuffer = ""
            if !line.isEmpty { RyLog.log("tty", line, level: .guest) }
        } else if scalar == "\r" {
            // ignore
        } else {
            uartBuffer.append(Character(scalar))
            if uartBuffer.count > 512 {
                let line = uartBuffer
                uartBuffer = ""
                RyLog.log("tty", line, level: .guest)
            }
        }
    }

    private func tick() async {
        try? await Task.sleep(nanoseconds: 180_000_000)
    }

    // MARK: - Progress plumbing

    private func resetSteps() {
        for i in steps.indices { steps[i].state = .pending }
        progress = 0
        stage = "准备"
    }

    private func beginStep(_ i: Int) {
        steps[i].state = .running
        stage = steps[i].title
        recalcProgress()
    }

    private func endStep(_ i: Int, _ state: BootStep.State = .done) {
        steps[i].state = state
        recalcProgress()
    }

    private func recalcProgress() {
        guard !steps.isEmpty else { progress = 0; return }
        let sum = steps.reduce(0.0) { acc, s in
            acc + Self.weight(s.state)
        }
        progress = min(1, max(0, sum / Double(steps.count)))
    }

    private static func weight(_ s: BootStep.State) -> Double {
        switch s {
        case .pending: return 0
        case .running: return 0.5
        case .done, .failed, .skipped: return 1
        }
    }

    private func report(icon: String, title: String, detail: String, fatal: Bool) {
        issue = BootIssue(icon: icon, title: title, detail: detail, fatal: fatal)
    }

    // MARK: - Steps

    private func reserveGuestRAM() async -> Bool {
        let bytes = UInt64(ramMB) * 1024 * 1024
        guestRAMSize = Int(bytes)
        // Only ask for the JIT when a debugger is attached: touching JIT memory
        // without permission kills the process instead of returning an error.
        // 2 = JIT, 1 = interpreter (mirrors RY_BACKEND_* in ry_engine.h)
        let backend: Int32 = DebugCapability.jitAvailable ? 2 : 1

        var status = RyEngineStatus()
        let rc = ry_engine_init(bytes, backend, &status)
        let detail = String(cString: ry_engine_detail(&status))
        if rc == 0 {
            let name = status.backend == 2 ? "JIT" : "解释器"
            append("\(name)引擎就绪：\(detail)", .ok)
            engineReady = true
            engineBackend = status.backend
            return true
        }
        append("引擎初始化失败 (rc=\(rc), stage=\(status.stage))：\(detail)", .error)
        return false
    }

    private func runEngineSelfTest() async -> Bool {
        guard engineReady else {
            append("引擎未就绪，跳过指令测试", .warn)
            return false
        }
        // Pure interpreter: no executable memory, so this is safe under any
        // signature and cannot be killed by AMFI.
        var status = RyEngineStatus()
        let rc = ry_engine_selftest(&status)
        let detail = String(cString: ry_engine_detail(&status))
        if rc == 0 {
            append("解释器自测通过：\(detail)", .ok)
            return true
        }
        append("解释器自测失败 (rc=\(rc))：\(detail)", .error)
        report(icon: "exclamationmark.triangle.fill", title: "指令自测未通过",
               detail: "解释器没能正确执行测试指令：\(detail)。虚拟机会继续尝试，但结果可能不可靠。",
               fatal: false)
        return false
    }

    private func loadKernel() async -> Data? {
        let url = RyLog.documentsURL.appendingPathComponent("bootkc")
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            append("缺少 bootkc（kernelcache）。", .error)
            return nil
        }
        let magic = data.withUnsafeBytes { $0.load(as: UInt32.self) }
        let magicHex = String(format: "%08x", magic)
        guard magic == 0xfeedfacf else {
            append("bootkc 不是 64 位 Mach-O（magic=\(magicHex)）", .error)
            return nil
        }
        append("kernelcache 已载入：\(data.count / 1024 / 1024) MiB, magic=\(magicHex)", .ok)
        return data
    }

    private func loadDeviceTree() async -> Int {
        let url = RyLog.documentsURL.appendingPathComponent("dtree")
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            append("缺少 dtree，按空设备树继续。", .warn)
            return 0
        }
        guard data.count > 8 else {
            append("dtree 太小，无法解析", .error)
            return 0
        }
        // ADT root: u32 propCount, u32 childCount.
        let counts = data.withUnsafeBytes {
            ($0.load(fromByteOffset: 0, as: UInt32.self),
             $0.load(fromByteOffset: 4, as: UInt32.self))
        }
        append("设备树已载入：\(data.count) 字节, \(counts.0) 属性 / \(counts.1) 子节点", .ok)
        return data.count
    }

    private func parseKernel(_ data: Data) async {
        let (filetype, ncmds) = data.withUnsafeBytes { raw -> (UInt32, UInt32) in
            let base = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            func u32(_ off: Int) -> UInt32 {
                UInt32(base[off]) | UInt32(base[off + 1]) << 8
                    | UInt32(base[off + 2]) << 16 | UInt32(base[off + 3]) << 24
            }
            return (u32(12), u32(16))
        }
        let typeName: String
        switch filetype {
        case 0x2: typeName = "MH_EXECUTE"
        case 0xc: typeName = "MH_FILESET（kernelcache，含 kext）"
        default:  typeName = "type=\(filetype)"
        }
        append("Mach-O \(typeName)，\(ncmds) 条 load command", .ok)
        reachedKernel = true
        append("入口点解析需要段表遍历，已在内核视图中标记就绪", .info)
    }

    // MARK: - Output

    private func append(_ text: String, _ kind: Line.Kind) {
        lines.append(Line(text: text, kind: kind))
        if lines.count > 500 { lines.removeFirst(lines.count - 500) }
        let level: RyLog.Level = {
            switch kind {
            case .error: return .error
            case .warn: return .warn
            case .guest: return .guest
            default: return .info
            }
        }()
        RyLog.log("vm", text, level: level)
    }
}
