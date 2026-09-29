import Foundation

/// Drives a real Session headlessly. Each step is its own trip to the main
/// actor, turning the main run loop briefly (the session's timer lives there)
/// and then returning, so work queued for the main thread (FSEvents, the end
/// of parking) gets to run in between, as it does in the app. The timeout is
/// generous because saves run at utility priority, which a busy machine
/// starves; it only matters when something is wrong.
func wait(_ condition: @escaping @MainActor () -> Bool, timeout: TimeInterval = 60) async -> Bool {
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
