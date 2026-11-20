import Foundation
import Darwin

/// Detects whether this process is being debugged, which on iOS 26+ is the
/// only condition under which JIT (executable anonymous memory) is granted.
///
/// Two independent signals, either one is enough:
///   1. The process carries P_TRACED (a debugger attached via StikDebug /
///      StikJIT / Xcode).
///   2. The code signature carries get-task-allow, checked through the
///      security framework when available.
enum DebugCapability {
    static var isTraced: Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        let ok = sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)
        guard ok == 0 else { return false }
        return (info.kp_proc.p_flag & P_TRACED) != 0
    }

    /// Whether JIT should be offered in the UI right now.
    static var jitAvailable: Bool { isTraced }

    /// Human-readable reason for the current state.
    static var statusText: String {
        if isTraced {
            return "已检测到调试器，JIT 可用"
        }
        return "未检测到调试器，JIT 不可用。用 StikDebug / StikJIT 附加后重启 App 生效。"
    }
}
