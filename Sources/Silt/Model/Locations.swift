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
}

enum Locations {
    static func all() -> [Location] {
        var result: [Location] = []
        let keys: [URLResourceKey] = [
            .volumeLocalizedNameKey, .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey, .volumeIsBrowsableKey,
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
                available: v.volumeAvailableCapacityForImportantUsage
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

    static func volumeCapacity(for url: URL) -> (total: Int64, available: Int64, free: Int64)? {
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
        ]
        guard let v = try? url.resourceValues(forKeys: keys), let total = v.volumeTotalCapacity else { return nil }
        let free = Int64(v.volumeAvailableCapacity ?? 0)
        return (Int64(total), v.volumeAvailableCapacityForImportantUsage ?? free, free)
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
