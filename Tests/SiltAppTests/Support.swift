import Foundation
@testable import Silt

/// Drives a real Session headlessly. Each step is its own trip to the main
/// actor, turning the main run loop briefly (the session's timer lives there)
/// and then returning, so work queued for the main thread (FSEvents, the end
/// of parking) gets to run in between, as it does in the app. The timeout is
/// generous because saves run at utility priority, which a busy machine
/// starves; it only matters when something is wrong.
func wait(_ condition: @escaping @MainActor () -> Bool, timeout: TimeInterval = 60) async -> Bool {
    await pinPace()
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if await MainActor.run(body: { RunLoop.main.run(until: Date().addingTimeInterval(0.02)); return condition() }) {
            return true
        }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await MainActor.run(body: condition)
}

func settle(_ seconds: TimeInterval) async {
    _ = await wait({ false }, timeout: seconds)
}

/// Sessions pace themselves by the speed setting and the power state: tests
/// run at Automatic on (pretend) mains power, whatever the machine is doing.
@MainActor
func pinPace() {
    // And no real snapshots: tests that need them give a scan its own ledger.
    if !SpaceLedger.testing { SpaceLedger.testing = true }
    let speed = SpeedController.shared
    if speed.pinnedConditions == nil { speed.pinnedConditions = PowerConditions() }
    if speed.mode != .automatic { speed.mode = .automatic }
}
