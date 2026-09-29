import Foundation
import os
import SiltCore

/// Saved scans, one per scanned location, so relaunching shows the last
/// result instantly and FSEvents replays only what changed since.
enum Snapshots {
    private static let flagFullDiskAccess: UInt32 = 1
    private static let log = Logger(subsystem: "com.jonnyasmar.silt", category: "snapshots")

    static var directory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("com.jonnyasmar.silt/Snapshots", isDirectory: true)
    }

    static func file(for root: String) -> URL {
        var h: UInt64 = 0xCBF2_9CE4_8422_2325
        for b in root.utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01B3 }
        return directory.appendingPathComponent(String(h, radix: 16) + ".snap")
    }

    /// Only local, internal volumes keep FSEvents history we can trust across
    /// launches; removable and network volumes always rescan.
    static func eligible(_ url: URL) -> Bool {
        if url.path == "/" { return true }
        let v = try? url.resourceValues(forKeys: [.volumeIsInternalKey, .volumeIsLocalKey])
        return v?.volumeIsInternal == true && v?.volumeIsLocal == true
    }

    struct Restored {
        let tree: UnsafeMutablePointer<silt_tree>
        let eventId: FSEventStreamEventId
        let savedAt: Date
        /// FSEvents can replay everything since, which brings it up to date.
        /// Otherwise it's only good to show while every folder is checked again.
        let replayable: Bool
    }

    /// Older than this and the FSEvents journal may no longer reach back.
    static let maxAge: TimeInterval = 7 * 86400

    static func load(for url: URL, fullDiskAccess: Bool) -> Restored? {
        guard eligible(url) else { return nil }
        let path = file(for: url.path).path
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var meta = silt_snapshot_meta()
        guard let tree = silt_tree_load(path, &meta) else {
            return discard(path, url, "it's damaged or from another version")
        }
        // Without Full Disk Access some folders were never opened; with it,
        // others were. Either way it's a different tree.
        guard (meta.flags & flagFullDiskAccess != 0) == fullDiskAccess else {
            silt_tree_destroy(tree)
            return discard(path, url, "Full Disk Access has changed since")
        }
        // The file names its own root; make sure it's the one we asked for.
        silt_tree_lock(tree)
        let root = withUnsafeTemporaryAllocation(of: CChar.self, capacity: 4096) { buf -> String in
            silt_path(tree, 0, buf.baseAddress!, 4096) > 0 ? String(cString: buf.baseAddress!) : ""
        }
        silt_tree_unlock(tree)
        guard root == url.path else {
            silt_tree_destroy(tree)
            return discard(path, url, "it describes \(root)")
        }
        var replayable = Date().timeIntervalSince1970 - meta.saved_at < maxAge
        if !replayable {
            log.notice("Saved scan of \(url.path, privacy: .public) is too old to catch up on; rechecking it")
        } else if let uuid = FSWatcher.databaseUUID(for: url.path) {
            replayable = withUnsafeBytes(of: uuid) { a in withUnsafeBytes(of: meta.volume_uuid) { b in a.elementsEqual(b) } }
            if !replayable {
                log.notice("File-system history for \(url.path, privacy: .public) was reset; rechecking the saved scan")
            }
        } else {
            replayable = false
        }
        return Restored(tree: tree, eventId: meta.event_id, savedAt: Date(timeIntervalSince1970: meta.saved_at),
                        replayable: replayable)
    }

    private static func discard(_ path: String, _ url: URL, _ why: String) -> Restored? {
        log.notice("Discarding the saved scan of \(url.path, privacy: .public): \(why, privacy: .public)")
        try? FileManager.default.removeItem(atPath: path)
        return nil
    }

    /// Whether the saved scan of `url` would still catch up by FSEvents replay
    /// if it were loaded now: young enough, same file-system history, same
    /// Full Disk Access. Reads only the header. `margin`: how much longer it
    /// must stay young enough.
    static func replayable(for url: URL, fullDiskAccess: Bool, margin: TimeInterval = 0) -> Bool {
        guard eligible(url) else { return false }
        var meta = silt_snapshot_meta()
        guard silt_snapshot_peek(file(for: url.path).path, &meta),
              (meta.flags & flagFullDiskAccess != 0) == fullDiskAccess,
              Date().timeIntervalSince1970 - meta.saved_at + margin < maxAge,
              let uuid = FSWatcher.databaseUUID(for: url.path) else { return false }
        return withUnsafeBytes(of: uuid) { a in withUnsafeBytes(of: meta.volume_uuid) { b in a.elementsEqual(b) } }
    }

    /// When the saved scan of `path` was last brought up to date, if there's
    /// one this build can open.
    static func savedAt(for path: String) -> Date? {
        var meta = silt_snapshot_meta()
        guard silt_snapshot_peek(file(for: path).path, &meta) else { return nil }
        return Date(timeIntervalSince1970: meta.saved_at)
    }

    /// Takes the tree lock while copying; call off the main thread when the
    /// tree is large. Returns false if the tree isn't settled yet.
    @discardableResult
    static func save(_ tree: Tree, url: URL, eventId: FSEventStreamEventId, fullDiskAccess: Bool) -> Bool {
        guard eligible(url) else { return false }
        guard let uuid = FSWatcher.databaseUUID(for: url.path) else {
            log.error("No file-system history for \(url.path, privacy: .public); can't save its scan")
            return false
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var meta = silt_snapshot_meta()
        meta.event_id = eventId
        meta.saved_at = Date().timeIntervalSince1970
        meta.flags = fullDiskAccess ? flagFullDiskAccess : 0
        withUnsafeMutableBytes(of: &meta.volume_uuid) { dst in
            withUnsafeBytes(of: uuid) { src in dst.copyMemory(from: src) }
        }
        return silt_tree_save(tree.raw, file(for: url.path).path, &meta)
    }

    static func discard(for url: URL) {
        try? FileManager.default.removeItem(at: file(for: url.path))
    }
}
