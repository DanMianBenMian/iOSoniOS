import Foundation

struct RySelfTestOutcome {
    let jitOK: Bool
    let pagesMatch: Bool
    let detail: String
}

enum RyEngineSelfTest {
    static func run() -> RySelfTestOutcome {
        var result = RySelfTestResult()
        ry_selftest_run(&result)

        let detail = withUnsafePointer(to: &result.detail) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 256) { p in
                String(cString: p)
            }
        }

        RyLog.log("自检", "页大小=\(result.page_size) 与 guest 匹配=\(result.pages_match == 1)")
        RyLog.log("自检", "RWX 申请=\(result.mmap_ok == 1 ? "成功" : "失败") 信号=\(result.fault_signal)")
        RyLog.log("自检", result.detail, level: result.jit_ok == 1 ? .info : .warn)

        return RySelfTestOutcome(
            jitOK: result.jit_ok == 1,
            pagesMatch: result.pages_match == 1,
            detail: detail
        )
    }
}
