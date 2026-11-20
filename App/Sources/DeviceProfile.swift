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

    /// Guest GPU memory estimate. Scales with guest RAM, CPU count and a
    /// rough device class factor. A14-class devices get the base multiplier.
    static func estimatedVRAMMB(ramGB: Double, cpuCores: Int) -> Int {
        let deviceFactor: Double
        let name = chipName
        if name.contains("iPad16") || name.contains("iPhone17") { deviceFactor = 1.35 }  // A18/M4 class
        else if name.contains("iPad13") || name.contains("iPhone13") { deviceFactor = 1.0 }  // A14 class
        else if name.hasPrefix("iPad") || name.hasPrefix("iPhone") { deviceFactor = 0.85 }
        else { deviceFactor = 1.5 }  // M-series
        let base = ramGB * 192.0
        let cpu = 0.85 + Double(cpuCores) * 0.12
        return Int((base * cpu * deviceFactor).rounded())
    }

    /// VRAM below this is considered low and gets the warning color.
    static var lowVRAMThresholdMB: Int { 384 }
}
