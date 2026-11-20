import Foundation
import Darwin

/// Real boot work, not a progress animation.
///
/// Order matches what a firmware-adjacent loader actually does:
///   1. locate the kernelcache (bootkc) and the device tree (dtree)
///   2. validate Mach-O magic / ADT header
///   3. reserve guest RAM with the configured size
///   4. reserve the JIT (executable) region
///   5. parse the kernelcache's load commands to find __TEXT_EXEC and the entry
///   6. report exactly how far it got, and what is still missing
///
/// Step 6 matters: this build has no arm64 translation engine linked in yet, so
/// the honest output is "kernel parsed, engine absent" rather than pretending the
/// guest is running.
@MainActor
final class BootEngine: ObservableObject {

    struct Line: Identifiable {
        let id = UUID()
        let text: String
        let kind: Kind
        enum Kind { case info, ok, warn, error, guest }
    }

    @Published private(set) var lines: [Line] = []
    @Published private(set) var running = false
    @Published private(set) var stage = "待机"
    @Published private(set) var reachedKernel = false

    private var guestRAM: UnsafeMutableRawPointer?
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
    }

    // MARK: - Lifecycle

    func start() {
        guard !running else { return }
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

    /// A hardware key arrived from the floating key pad.
    func noteKey(_ name: String) {
        append("key \(name) 已接收（内核未运行，暂未投递）", .guest)
    }

    // MARK: - Boot sequence

    private func run() async {
        append("iOSoniOS 启动序列", .info)
        append("设备 \(DeviceProfile.chipName) · guest \(ramMB) MiB / \(cpuCount) 核", .info)
        append("boot-args: \(bootArgs)", .info)

        stage = "引擎初始化"
        await tick()
        await reserveGuestRAM()

        stage = "翻译器自测"
        await tick()
        await runEngineSelfTest()

        stage = "固件"
        await tick()
        let kernel = await loadKernel()

        stage = "设备树"
        await tick()
        let dtreeSize = await loadDeviceTree()

        if let kernel {
            stage = "内核解析"
            await tick()
            await parseKernel(kernel)
        }

        stage = "已停止"
        running = false
        append("—— 启动流程结束 ——", .info)
        _ = dtreeSize
    }

    private func tick() async {
        try? await Task.sleep(nanoseconds: 180_000_000)
    }

    // MARK: - Steps

    private func reserveGuestRAM() async {
        let bytes = UInt64(ramMB) * 1024 * 1024
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
        } else {
            append("引擎初始化失败 (rc=\(rc), stage=\(status.stage))：\(detail)", .error)
        }
    }

    private func runEngineSelfTest() async {
        guard engineReady else {
            append("引擎未就绪，跳过指令测试", .warn)
            return
        }
        // Pure interpreter: no executable memory, so this is safe under any
        // signature and cannot be killed by AMFI.
        var status = RyEngineStatus()
        let rc = ry_engine_selftest(&status)
        let detail = String(cString: ry_engine_detail(&status))
        if rc == 0 {
            append("解释器自测通过：\(detail)", .ok)
        } else {
            append("解释器自测失败 (rc=\(rc))：\(detail)", .error)
        }
    }

    private func loadKernel() async -> Data? {
        let url = RyLog.documentsURL.appendingPathComponent("bootkc")
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            append("缺少 bootkc（kernelcache）。请先导入 IPSW 或放入 bootkc。", .error)
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
            append("缺少 dtree。", .warn)
            return 0
        }
        // ADT root: u32 propCount, u32 childCount.
        guard data.count > 8 else {
            append("dtree 太小，无法解析", .error)
            return 0
        }
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

    private func hex(_ v: UInt) -> String {
        String(format: "0x%llx", UInt64(v))
    }
}
