import CoreServices
import Foundation

/// A thin FSEvents stream: directory-level change notifications for a subtree.
final class FSWatcher {
    struct Event {
        let path: String
        let flags: FSEventStreamEventFlags

        var mustScanSubdirs: Bool { flags & UInt32(kFSEventStreamEventFlagMustScanSubDirs) != 0 }
        var rootChanged: Bool { flags & UInt32(kFSEventStreamEventFlagRootChanged) != 0 }
    }

    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "silt.fsevents", qos: .utility)
    private let handler: ([Event]) -> Void

    init(path: String, latency: TimeInterval = 0.4, handler: @escaping ([Event]) -> Void) {
        self.handler = handler
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<FSWatcher>.fromOpaque(info).takeUnretainedValue()
            let array = unsafeBitCast(paths, to: NSArray.self)
            var events: [Event] = []
            events.reserveCapacity(count)
            for i in 0..<count {
                guard let p = array[i] as? String else { continue }
                events.append(Event(path: p, flags: flags[i]))
            }
            watcher.handler(events)
        }
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)
        stream = FSEventStreamCreate(
            nil, callback, &context, [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags
        )
        if let stream {
            FSEventStreamSetDispatchQueue(stream, queue)
            FSEventStreamStart(stream)
        }
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}
