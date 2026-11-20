import Foundation

/// Device-aware limits for VM sizing.
///
/// iOS jetsam: the kernel kills the foreground app when its footprint approaches
/// a device-specific threshold. On a 4 GB iPad that ceiling is roughly 2–2.5 GB
/// of usable memory for one app. We leave a generous headroom and warn before
/// the user crosses it rather than silently letting the VM get killed.
enum DeviceProfile {
    static var totalRAMBytes: UInt64 {
        ProcessInfo.processInfo.physicalMemory
    }

    static var totalRAMGB: Double {
        Double(totalRAMBytes) / (1024.0 * 1024.0 * 1024.0)
    }

    /// Usable ceiling for a single app before jetsam risk, in GB.
    /// Approximates iOS's per-app memory limit with headroom for the OS + host.
    static var jetsamCeilingGB: Double {
        let ram = totalRAMGB
        if ram <= 3 { return ram * 0.45 }
        if ram <= 4 { return 2.0 }        // 4 GB iPad: warn at 2 GiB and above
        if ram <= 6 { return 3.0 }
        if ram <= 8 { return 4.5 }
        return ram * 0.60
    }

    /// Memory tiers from 1 GiB up to a device-dependent maximum, 5 steps.
    /// 4 GB device -> 1 / 1.5 / 2 / 2.5 / 3 GiB.
    static var memoryTiersGB: [Double] {
        let ram = totalRAMGB
        let maxGB: Double
        if ram <= 3 { maxGB = max(1.0, floor(ram - 1.0)) }
        else if ram <= 4 { maxGB = 3.0 }
        else if ram <= 6 { maxGB = 4.0 }
        else if ram <= 8 { maxGB = 6.0 }
        else { maxGB = floor(ram - 2.0) }
        let count = 5
        return (0..<count).map { i in
            maxGB == 1.0 ? 1.0 : 1.0 + (maxGB - 1.0) * Double(i) / Double(count - 1)
        }
    }

    /// Physical CPU cores reported by the kernel.
    static var physicalCores: Int {
        var n: Int32 = 0
        var size = MemoryLayout<Int32>.size
        sysctlbyname("hw.ncpu", &n, &size, nil, 0)
        return Int(max(1, n))
    }

    /// Host performance class, used for the VRAM estimate.
    static var chipName: String {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &buf, &size, nil, 0)
        return String(cString: buf)
    }

    /// Guest GPU memory estimate.
    ///
    /// This is a BUDGET, not an independent pool. iOS is unified-memory: the
    /// guest's RAM and its VRAM both come out of the same per-app jetsam
    /// ceiling. So raising RAM (or CPU count, which costs page tables and
    /// per-core JIT/TLB state) must LOWER the VRAM figure, not raise it.
    /// An earlier version scaled VRAM up with RAM, which was backwards.
    static func estimatedVRAMMB(ramGB: Double, cpuCores: Int) -> Int {
        let deviceFactor: Double
        let name = chipName
        if name.contains("iPad16") || name.contains("iPhone17") { deviceFactor = 1.35 }  // A18/M4 class
        else if name.contains("iPad13") || name.contains("iPhone13") { deviceFactor = 1.0 }  // A14 class
        else if name.hasPrefix("iPad") || name.hasPrefix("iPhone") { deviceFactor = 0.85 }
        else { deviceFactor = 1.5 }  // M-series

        // Total guest budget the host can afford, in MB.
        let budgetMB = max(2048.0, jetsamCeilingGB * 1024.0 * 1.5)
        let ramMB = ramGB * 1024.0
        let freeRatio = max(0.0, min(1.0, 1.0 - ramMB / budgetMB))

        // More cores = more per-core VM/JIT state, so less left for the GPU.
        let cpuPenalty = max(0.55, 1.0 - Double(max(0, cpuCores - 1)) * 0.07)

        // 1 GiB guest leaves ~0.67 of the budget free on a 4 GB iPad.
        let base = 1024.0 * freeRatio * cpuPenalty * deviceFactor
        return max(128, min(1024, Int(base.rounded())))
    }

    /// VRAM below this is considered low and gets the warning color.
    static var lowVRAMThresholdMB: Int { 384 }

    /// True when guest RAM is high enough that VRAM has been squeezed flat.
    static func vramIsSqueezed(ramGB: Double) -> Bool {
        estimatedVRAMMB(ramGB: ramGB, cpuCores: 1) <= 160
    }
}
