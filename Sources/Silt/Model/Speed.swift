import Foundation
import IOKit.ps
import Observation
import SiltCore

/// How hard Silt works. Automatic decides moment to moment; the others pin it.
enum ScanSpeed: String, CaseIterable, Identifiable {
    case automatic, fast, gentle, paused

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .fast: "Fast"
        case .gentle: "Gentle"
        case .paused: "Paused"
        }
    }

    var symbol: String {
        switch self {
        case .automatic: "gauge.with.dots.needle.50percent"
        case .fast: "hare"
        case .gentle: "tortoise"
        case .paused: "pause.circle"
        }
    }

    var detail: String {
        switch self {
        case .automatic:
            "Scans you start run at full speed. Keeping up with changes runs in the background, and everything eases off on battery, in Low Power Mode, or when the Mac runs hot."
        case .fast:
            "Everything at full priority, catching up included. For when you want the answer now."
        case .gentle:
            "Low priority on the efficiency cores, with slower disk access. Scans take longer; you won’t notice them."
        case .paused:
            "Silt does nothing on its own: no catching up, no updates as files change. Scans you start still run, and changes are caught up on when you resume."
        }
    }
}

/// What the Mac is doing, as far as pace goes.
struct PowerConditions: Equatable {
    var lowPower = false
    var onBattery = false
    var thermal: ProcessInfo.ThermalState = .nominal

    var hot: Bool { thermal == .serious || thermal == .critical }
}

/// The Mac's cores, by kind (Intel Macs have no efficiency cores).
struct CoreCounts: Equatable {
    var performance: Int
    var efficiency: Int

    static let current: CoreCounts = {
        func count(_ name: String) -> Int? {
            var value: Int32 = 0
            var size = MemoryLayout<Int32>.size
            return sysctlbyname(name, &value, &size, nil, 0) == 0 ? Int(value) : nil
        }
        if let p = count("hw.perflevel0.logicalcpu") {
            return CoreCounts(performance: p, efficiency: count("hw.perflevel1.logicalcpu") ?? 0)
        }
        return CoreCounts(performance: ProcessInfo.processInfo.activeProcessorCount, efficiency: 0)
    }()
}

/// How hard the scanner works, and how often Silt looks at what changed.
struct Pace: Equatable {
    enum QoS: Equatable { case userInitiated, utility, background }

    /// Work you asked for: scans, rescans, refreshes after you remove things.
    var urgentQoS: QoS
    /// Most of those listings at once; 0 lets the scanner decide.
    var urgentMax: UInt32
    /// Silt's own upkeep: keeping a finished scan current.
    var backgroundQoS: QoS
    /// 0 holds upkeep back entirely (Paused).
    var backgroundMax: UInt32
    var paused = false
    /// Whether catching up after a relaunch or a nap counts as work you asked
    /// for, or as upkeep.
    var catchUpUrgent = false
    /// Multiplies how long busy folders wait between updates.
    var paceFactor: Double = 1

    /// Silt's own upkeep is held back (Paused).
    var upkeepPaused: Bool { paused || backgroundMax == 0 }
    /// Why Automatic is easing off, if it is ("Low Power Mode").
    var reason: String?

    var silt: silt_pace {
        func q(_ q: QoS) -> silt_qos {
            switch q {
            case .userInitiated: SILT_QOS_USER_INITIATED
            case .utility: SILT_QOS_UTILITY
            case .background: SILT_QOS_BACKGROUND
            }
        }
        return silt_pace(urgent_qos: q(urgentQoS), urgent_max: urgentMax, background_qos: q(backgroundQoS),
                         background_max: backgroundMax, paused: paused)
    }
}

enum SpeedPolicy {
    /// The pace `mode` means right now. Measured on a 1.2M-item folder
    /// (claudedocs/speed-plan-2026-10-05.md): full speed took 7–9 s for 21 s
    /// of CPU; utility QoS four at a time 19 s for 16–18 s, under one core on
    /// average; background QoS four at a time 18–61 s, depending on how busy
    /// the efficiency cores were.
    static func pace(_ mode: ScanSpeed, _ c: PowerConditions, cores: CoreCounts = .current) -> Pace {
        let gentle = Pace(urgentQoS: .background, urgentMax: UInt32(max(2, cores.efficiency)),
                          backgroundQoS: .background, backgroundMax: 1, paceFactor: 4)
        switch mode {
        case .fast:
            return Pace(urgentQoS: .userInitiated, urgentMax: 0, backgroundQoS: .userInitiated,
                        backgroundMax: UInt32(max(4, cores.performance / 2)), catchUpUrgent: true)
        case .gentle:
            return gentle
        case .paused:
            // Upkeep waits; what you start still runs (a rescan, a scan of
            // somewhere new, the refresh after you put something back).
            var p = pace(.automatic, c, cores: cores)
            p.backgroundMax = 0
            p.reason = nil
            return p
        case .automatic:
            if c.lowPower || c.hot {
                return Pace(urgentQoS: .utility, urgentMax: UInt32(max(2, cores.performance / 2)),
                            backgroundQoS: .background, backgroundMax: 1, paceFactor: 4,
                            reason: c.lowPower ? "Low Power Mode" : "the Mac is running hot")
            }
            if c.onBattery {
                return Pace(urgentQoS: .userInitiated, urgentMax: 0, backgroundQoS: .background, backgroundMax: 2,
                            paceFactor: 2, reason: "on battery")
            }
            return Pace(urgentQoS: .userInitiated, urgentMax: 0, backgroundQoS: .utility, backgroundMax: 4)
        }
    }
}

extension Notification.Name {
    /// The pace changed: sessions re-read `SpeedController.shared.pace`.
    static let siltPaceChanged = Notification.Name("SiltPaceChanged")
}

/// Owns the speed setting, watches the power state, and applies the pace to
/// every scanner.
@MainActor
@Observable
final class SpeedController {
    static let shared = SpeedController()

    var mode: ScanSpeed {
        didSet {
            guard mode != oldValue else { return }
            UserDefaults.standard.set(mode.rawValue, forKey: Self.key)
            update()
        }
    }
    private(set) var conditions = PowerConditions()
    private(set) var pace: Pace
    /// Conditions to use instead of the Mac's (tests: the result mustn't
    /// depend on whether the machine is on battery).
    @ObservationIgnored var pinnedConditions: PowerConditions? {
        didSet { conditionsChanged() }
    }

    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var powerSource: CFRunLoopSource?
    private static let key = "scanSpeed"

    private init() {
        let mode = UserDefaults.standard.string(forKey: Self.key).flatMap(ScanSpeed.init) ?? .automatic
        self.mode = mode
        let now = Self.readConditions()
        conditions = now
        pace = SpeedPolicy.pace(mode, now)
        // No notification from here: observers would read `shared` while
        // it's still being made.
        Tree.setPace(pace.silt)
        let center = NotificationCenter.default
        for name in [Notification.Name.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { SpeedController.shared.conditionsChanged() }
            })
        }
        // The power adapter coming and going.
        let source = IOPSNotificationCreateRunLoopSource({ _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { SpeedController.shared.conditionsChanged() } }
        }, nil)?.takeRetainedValue()
        if let source {
            // Common modes: it still fires during menu tracking and modals.
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            powerSource = source
        }
    }

    private static func readConditions() -> PowerConditions {
        var c = PowerConditions()
        c.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        c.thermal = ProcessInfo.processInfo.thermalState
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() {
            c.onBattery = (type as String) == kIOPMBatteryPowerKey
        }
        return c
    }

    private func conditionsChanged() {
        let next = pinnedConditions ?? Self.readConditions()
        guard next != conditions else { return }
        conditions = next
        update()
    }

    private func update() {
        let next = SpeedPolicy.pace(mode, conditions)
        if next != pace { pace = next }
        Tree.setPace(next.silt)
        NotificationCenter.default.post(name: .siltPaceChanged, object: nil)
    }
}
