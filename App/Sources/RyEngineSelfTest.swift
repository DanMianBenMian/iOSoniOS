import Foundation

struct RySelfTestOutcome {
    let jitOK: Bool
    let pagesMatch: Bool
    let detail: String
}

enum RyEngineSelfTest {
    /// Convert a fixed-size C char array (imported as a tuple) to a String.
    static func cString<T>(from value: inout T, capacity: Int) -> String {
        return withUnsafeBytes(of: &value) { raw in
            guard let base = raw.baseAddress else { return "" }
            let ptr = base.assumingMemoryBound(to: CChar.self)
            return String(cString: ptr)
        }
    }

    static func run() -> RySelfTestOutcome {
        var result = RySelfTestResult()
        ry_selftest_run(&result)

        let detail = RyEngineSelfTest.cString(from: &result.detail, capacity: 256)

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
