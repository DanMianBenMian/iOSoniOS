import Foundation
import Darwin
import os

/// Unified low-level log for the guest kernel, the engine, and the host shell.
///
/// Everything lands in three places at once, in the same order:
///   * Documents/iosonios.log  -- retrievable from the Files app / share sheet
///   * os_log                  -- live in Console.app with the device attached
///   * an in-memory ring       -- for the in-app viewer (no computer needed)
///
/// Every line is fsync'd immediately: "auto-persist at any moment" means a crash
/// or a force-quit cannot lose the last diagnostic. This mirrors Henge's
/// HengeLog design, which exists for exactly the same reason: on iOS, stderr
/// from C code goes nowhere a user can reach.
enum RyLog {
    static let subsystem = "com.rybox.iosonios"

    enum Level: String, CaseIterable {
        case trace, info, warn, error, guest
    }

    private static let osLog = Logger(subsystem: subsystem, category: "engine")
    private static let writeLock = NSLock()
    private static let ringLock = NSLock()
    private static var ring: [Entry] = []
    private static let ringLimit = 4000
    private static var logFD: Int32 = -1
    private static var pipeReadFD: Int32 = -1
    private static var pipeWriteFD: Int32 = -1
    private static var started = false
    private static let startTime = Date()

    struct Entry: Identifiable, Codable {
        let id: Int
        let time: String
        let level: String
        let tag: String
        let message: String
    }

    static var logFileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iosonios.log")
    }

    static var previousLogFileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iosonios-prev.log")
    }

    static var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    // MARK: - Startup

    static func start() {
        guard !started else { return }
        started = true
        signal(SIGPIPE, SIG_IGN)

        // Keep the previous run: it is the crash report when this run was born
        // from a relaunch after a failure.
        try? FileManager.default.removeItem(at: previousLogFileURL)
        try? FileManager.default.moveItem(at: logFileURL, to: previousLogFileURL)
        logFD = open(logFileURL.path, O_CREAT | O_WRONLY | O_TRUNC, 0o644)

        redirectStdio()
        installCrashHandlers()
        banner()
        log("boot", "log file: \(logFileURL.path)", level: .info)
    }

    /// Divert C stdout/stderr into a pipe drained by our reader thread, so
    /// fprintf() from the engine and the guest UART become log lines.
    private static func redirectStdio() {
        var fds = [Int32](repeating: 0, count: 2)
        guard pipe(&fds) == 0 else { return }
        pipeReadFD = fds[0]
        pipeWriteFD = fds[1]
        dup2(pipeWriteFD, STDOUT_FILENO)
        dup2(pipeWriteFD, STDERR_FILENO)

        Thread.detachNewThread {
            var buf = [UInt8](repeating: 0, count: 8192)
            var partial = ""
            while true {
                let n = read(pipeReadFD, &buf, buf.count)
                if n <= 0 { break }
                partial += String(decoding: buf[0..<n], as: UTF8.self)
                while let nl = partial.firstIndex(of: "\n") {
                    let line = String(partial[partial.startIndex..<nl])
                    partial.removeSubrange(...nl)
                    log("native", line, level: .guest)
                }
            }
            if !partial.isEmpty { log("native", partial, level: .guest) }
        }
    }

    // A C signal handler must be a @convention(c) closure that captures no
    // context, so the fds it needs are mirrored into file-scope globals.
    fileprivate static var handlerLogFD: Int32 { logFD }
    fileprivate static var handlerPipeFD: Int32 { pipeWriteFD }

    private static func installCrashHandlers() {
        for sig in [SIGSEGV, SIGBUS, SIGABRT, SIGILL, SIGFPE] {
            signal(sig, crashHandler)
        }
    }

    private static func banner() {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        log("boot", "=== iOSoniOS session \(fmt.string(from: startTime)) ===", level: .info)
        log("boot", "device: \(ProcessInfo.processInfo.machineName)", level: .info)
    }

    // MARK: - Writing

    static func log(_ tag: String, _ message: String, level: Level = .info) {
        let now = Date()
        let elapsed = now.timeIntervalSince(startTime)
        let ts = String(format: "%08.3f", elapsed)
        let entry = Entry(id: nextID(), time: ts, level: level.rawValue, tag: tag, message: message)

        ringLock.lock()
        ring.append(entry)
        if ring.count > ringLimit { ring.removeFirst(ring.count - ringLimit) }
        ringLock.unlock()

        let line = "[\(ts)] \(level.rawValue.uppercased()) \(tag): \(message)\n"
        writeLock.lock()
        if logFD >= 0 {
            line.withCString { _ = write(logFD, $0, strlen($0)) }
            fsync(logFD)           // auto-persist: never lose a line
        }
        writeLock.unlock()

        switch level {
        case .error: osLog.error("\(tag): \(message)")
        case .warn:  osLog.warning("\(tag): \(message)")
        case .guest: osLog.debug("GUEST \(tag): \(message)")
        default:     osLog.info("\(tag): \(message)")
        }
    }

    static func guestSerial(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        let text = String(decoding: bytes, as: UTF8.self)
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty { log("serial", line, level: .guest) }
        }
    }

    private static var counter = 0
    private static let counterLock = NSLock()
    private static func nextID() -> Int {
        counterLock.lock(); defer { counterLock.unlock() }
        counter += 1
        return counter
    }

    static func recent(_ n: Int = 400) -> [Entry] {
        ringLock.lock(); defer { ringLock.unlock() }
        return Array(ring.suffix(n))
    }

    static func clearRing() {
        ringLock.lock(); ring.removeAll(); ringLock.unlock()
    }
}

/// Signal-safe crash handler: no allocations, no captured context.
private let crashHandler: @convention(c) (Int32) -> Void = { s in
    let fd = RyLog.handlerLogFD
    let msg = "CRASH signal \(s)\n"
    msg.withCString { _ = write(fd, $0, strlen($0)) }
    if fd >= 0 { fsync(fd) }
    let pipe = RyLog.handlerPipeFD
    if pipe >= 0 { _ = write(pipe, msg, msg.utf8.count) }
    exit(128 + s)
}

extension ProcessInfo {
    var machineName: String {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &buf, &size, nil, 0)
        return String(cString: buf)
    }
}
