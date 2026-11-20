import Foundation

struct RySelfTestOutcome {
    let jitOK: Bool
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
        RyLog.log("selftest", "page_size=\(result.page_size) guest/host 16K match=\(result.pages_match)")
        return RySelfTestOutcome(jitOK: result.jit_ok != 0, detail: detail)
    }
}
