import CoreServices
import Foundation

/// A thin FSEvents stream: directory-level change notifications for a subtree,
/// optionally replaying history from a saved event id.
final class FSWatcher {
    struct Event {
        let path: String
        let flags: FSEventStreamEventFlags
        let id: FSEventStreamEventId

        var mustScanSubdirs: Bool { flags & UInt32(kFSEventStreamEventFlagMustScanSubDirs) != 0 }
        var rootChanged: Bool { flags & UInt32(kFSEventStreamEventFlagRootChanged) != 0 }
        /// Marks the end of replayed history when started from a past id.
        var historyDone: Bool { flags & UInt32(kFSEventStreamEventFlagHistoryDone) != 0 }
        /// Ids wrapped: continuity with any saved id is lost.
        var idsWrapped: Bool { flags & UInt32(kFSEventStreamEventFlagEventIdsWrapped) != 0 }
    }

    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "silt.fsevents", qos: .utility)
    private let handler: ([Event]) -> Void
    /// Changes after this id are delivered. Without `since`, it's the newest
    /// id at creation, and the stream starts from it, so nothing that happens
    /// between reading it and starting the stream can slip through.
    let startId: FSEventStreamEventId
    /// False if the stream couldn't be created or started.
    private(set) var running = false

    init(path: String, since: FSEventStreamEventId? = nil, latency: TimeInterval = 0.4,
         handler: @escaping ([Event]) -> Void) {
        self.handler = handler
        startId = since ?? FSEventsGetCurrentEventId()
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, ids in
            guard let info else { return }
            let watcher = Unmanaged<FSWatcher>.fromOpaque(info).takeUnretainedValue()
            let array = unsafeBitCast(paths, to: NSArray.self)
            var events: [Event] = []
            events.reserveCapacity(count)
            for i in 0..<count {
                guard let p = array[i] as? String else { continue }
                events.append(Event(path: p, flags: flags[i], id: ids[i]))
            }
            watcher.handler(events)
        }
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)
        stream = FSEventStreamCreate(nil, callback, &context, [path] as CFArray, startId, latency, flags)
        if let stream {
            FSEventStreamSetDispatchQueue(stream, queue)
            running = FSEventStreamStart(stream)
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

    /// Identifies the FSEvents database that event ids for `path` belong to.
    static func databaseUUID(for path: String) -> uuid_t? {
        var st = stat()
        let probe = path == "/" ? "/System/Volumes/Data" : path
        guard stat(probe, &st) == 0, let uuid = FSEventsCopyUUIDForDevice(st.st_dev) else { return nil }
        let bytes = CFUUIDGetUUIDBytes(uuid)
        return (bytes.byte0, bytes.byte1, bytes.byte2, bytes.byte3, bytes.byte4, bytes.byte5, bytes.byte6,
                bytes.byte7, bytes.byte8, bytes.byte9, bytes.byte10, bytes.byte11, bytes.byte12, bytes.byte13,
                bytes.byte14, bytes.byte15)
    }
}
