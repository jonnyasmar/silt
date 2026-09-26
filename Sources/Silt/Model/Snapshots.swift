import Foundation
import SiltCore

/// Saved scans, one per scanned location, so relaunching shows the last
/// result instantly and FSEvents replays only what changed since.
enum Snapshots {
    private static let flagFullDiskAccess: UInt32 = 1

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
    }

    /// Older than this and the FSEvents journal may no longer reach back.
    private static let maxAge: TimeInterval = 7 * 86400

    static func load(for url: URL, fullDiskAccess: Bool) -> Restored? {
        guard eligible(url) else { return nil }
        let path = file(for: url.path).path
        var meta = silt_snapshot_meta()
        guard let tree = silt_tree_load(path, &meta) else { return nil }
        var ok = (meta.flags & flagFullDiskAccess != 0) == fullDiskAccess
            && Date().timeIntervalSince1970 - meta.saved_at < maxAge
        if ok, let uuid = FSWatcher.databaseUUID(for: url.path) {
            ok = withUnsafeBytes(of: uuid) { a in withUnsafeBytes(of: meta.volume_uuid) { b in a.elementsEqual(b) } }
        } else {
            ok = false
        }
        // The file names its own root; make sure it's the one we asked for.
        if ok {
            silt_tree_lock(tree)
            let root = withUnsafeTemporaryAllocation(of: CChar.self, capacity: 4096) { buf -> String in
                silt_path(tree, 0, buf.baseAddress!, 4096) > 0 ? String(cString: buf.baseAddress!) : ""
            }
            silt_tree_unlock(tree)
            ok = root == url.path
        }
        guard ok else {
            silt_tree_destroy(tree)
            try? FileManager.default.removeItem(atPath: path)
            return nil
        }
        return Restored(tree: tree, eventId: meta.event_id, savedAt: Date(timeIntervalSince1970: meta.saved_at))
    }

    /// Takes the tree lock while copying; call off the main thread when the
    /// tree is large. Returns false if the tree isn't settled yet.
    @discardableResult
    static func save(_ tree: Tree, url: URL, eventId: FSEventStreamEventId, fullDiskAccess: Bool) -> Bool {
        guard eligible(url), let uuid = FSWatcher.databaseUUID(for: url.path) else { return false }
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
