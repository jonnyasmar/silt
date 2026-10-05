import Darwin
import Foundation
import os

/// Where Silt's time goes, written to the unified log every 30 s and at key
/// moments (a restore, the end of catching up, rescans, analysis passes,
/// saves). Read it with:
///
///     log show --last 1h --info --predicate 'subsystem == "com.jonnyasmar.silt" AND category == "perf"'
enum Perf {
    static let log = Logger(subsystem: "com.jonnyasmar.silt", category: "perf")

    private static let tallies = OSAllocatedUnfairLock(initialState: [String: (count: Int, seconds: Double)]())

    /// Adds one run of `name` taking `seconds` to the current tally (any thread).
    static func note(_ name: String, seconds: Double) {
        tallies.withLock { t in
            let old = t[name] ?? (0, 0)
            t[name] = (old.count + 1, old.seconds + seconds)
        }
    }

    /// Times `body` (wall clock) into `name`'s tally.
    static func measure<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
        let start = ProcessInfo.processInfo.systemUptime
        defer { note(name, seconds: ProcessInfo.processInfo.systemUptime - start) }
        return try body()
    }

    /// The tallies since the last call, emptied.
    static func drain() -> [String: (count: Int, seconds: Double)] {
        tallies.withLock { t in
            defer { t = [:] }
            return t
        }
    }

    /// CPU seconds the whole process has used.
    static func processCPU() -> Double {
        var r = rusage()
        getrusage(RUSAGE_SELF, &r)
        return Double(r.ru_utime.tv_sec + r.ru_stime.tv_sec) + Double(r.ru_utime.tv_usec + r.ru_stime.tv_usec) / 1e6
    }

    /// CPU seconds the calling thread has used.
    static func threadCPU() -> Double {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
        let port = mach_thread_self()
        defer { mach_port_deallocate(mach_task_self_, port) }
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(port, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return Double(info.user_time.seconds + info.system_time.seconds)
            + Double(info.user_time.microseconds + info.system_time.microseconds) / 1e6
    }
}

/// Every 30 s: the process's CPU (and the main thread's share), the tallies,
/// and each open location's state.
@MainActor
enum PerfReporter {
    private static var timer: Timer?
    private static var lastCPU = 0.0, lastMain = 0.0
    private static var lastListed: [ObjectIdentifier: UInt64] = [:]
    private static var lastTicks: [ObjectIdentifier: Int] = [:]

    static func start() {
        lastCPU = Perf.processCPU()
        lastMain = Perf.threadCPU()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            MainActor.assumeIsolated { report() }
        }
        timer?.tolerance = 3
    }

    private static func report() {
        let cpu = Perf.processCPU(), main = Perf.threadCPU()
        let tallies = Perf.drain().sorted { $0.value.seconds > $1.value.seconds }
            .map { "\($0.key) \($0.value.count)×\(String(format: "%.2f", $0.value.seconds))s" }
            .joined(separator: ", ")
        var lines: [String] = []
        for s in WindowModel.allSessions {
            let id = ObjectIdentifier(s)
            let p = s.tree.progress
            // Parking and waking start the count again.
            let before = lastListed[id] ?? p.listed
            let listed = p.listed >= before ? p.listed - before : p.listed
            let ticks = s.ticks - (lastTicks[id] ?? s.ticks)
            lastListed[id] = p.listed
            lastTicks[id] = s.ticks
            lines.append("\(s.title): \(s.perfState) listed+\(listed) ticks+\(ticks) queued \(p.queued) urgent \(p.urgent_queued) threads \(p.threads)")
        }
        Perf.log.notice("""
            cpu \(String(format: "%.2f", cpu - lastCPU), privacy: .public)s/30s (main thread \(String(format: "%.2f", main - lastMain), privacy: .public)s) \
            | \(tallies, privacy: .public) | \(lines.joined(separator: " ; "), privacy: .public)
            """)
        lastCPU = cpu
        lastMain = main
    }
}
