import AppKit
import Foundation

struct Location: Identifiable, Hashable {
    let url: URL
    let name: String
    let symbol: String
    let isVolume: Bool
    let total: Int64?
    let available: Int64?

    var id: String { url.path }

    var usedFraction: Double? {
        guard let total, let available, total > 0 else { return nil }
        return Double(total - available) / Double(total)
    }

    func with(available: Int64?) -> Location {
        Location(url: url, name: name, symbol: symbol, isVolume: isVolume, total: total, available: available)
    }
}

/// A volume's size and free space. `available` also counts what macOS can
/// purge on demand (Finder's "available"); between exact checks it's `free`
/// plus the purgeable share last measured.
struct Capacity: Equatable, Sendable {
    var total: Int64
    var available: Int64
    var free: Int64

    /// Whether any figure moved by more than sizes show (a leading digit
    /// and one decimal, so under 0.05% can't show; at least 1 MB). Free
    /// space on a busy disk moves by kilobytes between checks, and
    /// redrawing for that is waste.
    func differsVisibly(from other: Capacity) -> Bool {
        func apart(_ a: Int64, _ b: Int64) -> Bool { abs(a - b) > max(1_000_000, max(a, b) / 2000) }
        return apart(total, other.total) || apart(available, other.available) || apart(free, other.free)
    }
}

enum Locations {
    /// Mounted volumes plus Home. Cheap enough for the main thread: it asks
    /// for plain free space, not the purgeable-aware figure (which takes
    /// 10–140 ms a volume); `withImportantUsage` fills that in off the main
    /// thread.
    static func all() -> [Location] {
        var result: [Location] = []
        let keys: [URLResourceKey] = [
            .volumeLocalizedNameKey, .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey, .volumeIsBrowsableKey,
            .volumeIsInternalKey, .volumeIsRemovableKey, .volumeIsRootFileSystemKey,
        ]
        let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        for url in volumes {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.volumeIsBrowsable != false else { continue }
            let root = v.volumeIsRootFileSystem == true
            let symbol = root ? "internaldrive" : (v.volumeIsInternal == true ? "internaldrive" : "externaldrive")
            result.append(Location(
                url: url,
                name: v.volumeLocalizedName ?? url.lastPathComponent,
                symbol: symbol,
                isVolume: true,
                total: v.volumeTotalCapacity.map(Int64.init),
                available: v.volumeAvailableCapacity.map(Int64.init)
            ))
        }
        result.sort { a, b in
            if a.url.path == "/" { return true }
            if b.url.path == "/" { return false }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        result.insert(Location(
            url: home, name: "Home", symbol: "house", isVolume: false, total: nil, available: nil
        ), at: min(1, result.count))
        return result
    }

    /// `locations` with each volume's available space counting what macOS
    /// can purge, and how much that adds to plain free space, by volume path.
    /// Slow (a query per volume): call it off the main thread.
    static func withImportantUsage(_ locations: [Location]) -> (locations: [Location], purgeable: [String: Int64]) {
        var purgeable: [String: Int64] = [:]
        let refined = locations.map { l -> Location in
            guard l.isVolume,
                  let v = try? l.url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey,
                                                               .volumeAvailableCapacityKey]),
                  let important = v.volumeAvailableCapacityForImportantUsage else { return l }
            if let free = v.volumeAvailableCapacity { purgeable[l.id] = important - Int64(free) }
            return l.with(available: important)
        }
        return (refined, purgeable)
    }

    /// The exact figures, purgeable space included. Takes 10–140 ms (the
    /// purgeable part is the slow one): call it off the main thread.
    static func volumeCapacity(for url: URL) -> Capacity? {
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
        ]
        guard let v = try? url.resourceValues(forKeys: keys), let total = v.volumeTotalCapacity else { return nil }
        let free = Int64(v.volumeAvailableCapacity ?? 0)
        return Capacity(total: Int64(total), available: v.volumeAvailableCapacityForImportantUsage ?? free, free: free)
    }

    /// Total and free space from `statfs`: the same numbers as the total and
    /// available-capacity keys, in microseconds, but without purgeable space.
    static func quickCapacity(for path: String) -> (total: Int64, free: Int64)? {
        var fs = statfs()
        guard statfs(path, &fs) == 0, fs.f_blocks > 0 else { return nil }
        let block = Int64(fs.f_bsize)
        return (Int64(fs.f_blocks) * block, Int64(fs.f_bavail) * block)
    }

    static func displayName(for url: URL) -> String {
        if url.path == "/" {
            return (try? url.resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName) ?? "Macintosh HD"
        }
        if url.path == FileManager.default.homeDirectoryForCurrentUser.path { return "Home" }
        return FileManager.default.displayName(atPath: url.path)
    }
}

enum FullDiskAccess {
    /// The TCC database is readable only with Full Disk Access.
    static var isGranted: Bool {
        let probe = "/Library/Application Support/com.apple.TCC/TCC.db"
        let fd = open(probe, O_RDONLY)
        if fd >= 0 {
            close(fd)
            return true
        }
        return false
    }

    static func openSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",
        ]
        for s in urls {
            if let url = URL(string: s), NSWorkspace.shared.open(url) { return }
        }
    }
}
