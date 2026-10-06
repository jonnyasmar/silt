import Foundation

/// What a volume's used space holds beyond the files a scan can reach: other
/// volumes sharing its APFS container, space macOS can purge (local Time
/// Machine snapshots, evictable caches), and folders only macOS can read.
struct HiddenSpace: Equatable {
    struct Part: Identifiable, Equatable {
        enum Kind { case purgeable, held, volume, unmounted, unreadable }
        let id: String
        let kind: Kind
        let title: String
        let detail: String
        let bytes: Int64
    }

    /// Used minus scanned.
    let total: Int64
    let parts: [Part]
    /// Local snapshots of the scanned volume, oldest first (by name).
    let snapshots: [String]

    /// Breaks down `used − scanned` for the volume at `url`. `capacity` is the
    /// container's (APFS volumes share it); nil if the gap is too small to
    /// mention.
    /// `held`: what local snapshots still keep of what Silt removed.
    static func measure(url: URL, scanned: Int64, capacity: Capacity,
                        unreadable: Int, excluded: Int = 0, snapshots: [String], held: Int64 = 0) -> HiddenSpace? {
        let used = capacity.total - capacity.free
        let gap = used - scanned
        guard gap > capacity.total / 200 else { return nil }

        let mounts = Mounts.all()
        let scannedPaths: Set<String> = url.path == "/" ? ["/", "/System/Volumes/Data"] : [url.path]
        guard let home = mounts.first(where: { $0.path == url.path }), let container = home.container else {
            return HiddenSpace(total: gap, parts: [], snapshots: snapshots)
        }
        // Only volumes on this disk are asked for their usage: a disk image
        // served over the network could stall the question.
        let siblings = mounts.filter { $0.container == container }.map(Mounts.withUsage)
        let scannedUsed = siblings.filter { scannedPaths.contains($0.path) }.reduce(Int64(0)) { $0 + $1.used }
        var parts: [Part] = []

        // Space on the scanned volumes themselves that the scan didn't see.
        var onVolume = max(0, scannedUsed - scanned)
        let purgeable = min(onVolume, max(0, capacity.available - capacity.free))
        if purgeable > 0 {
            let snaps = snapshots.isEmpty ? "" :
                " That includes \(snapshots.count) local Time Machine snapshot\(snapshots.count == 1 ? "" : "s")."
            parts.append(Part(id: "purgeable", kind: .purgeable, title: "Purgeable",
                              detail: "Space macOS frees by itself when it needs room: local snapshots and caches it can rebuild.\(snaps)",
                              bytes: purgeable))
            onVolume -= purgeable
        }

        // What Silt removed that snapshots still keep: named, so the
        // popover and this breakdown agree. Out of what's left, since macOS
        // may or may not count it as purgeable.
        let kept = min(held, onVolume)
        if kept >= 100_000_000 {
            parts.append(Part(id: "held", kind: .held, title: "Removed by Silt, kept by snapshots",
                              detail: "What Silt deleted that local Time Machine snapshots still hold. It comes back as they go.",
                              bytes: kept))
            onVolume -= kept
        }

        // Other volumes in the same container: swap, startup files.
        for m in siblings where !scannedPaths.contains(m.path) && m.used >= 100_000_000 {
            let name = (m.path as NSString).lastPathComponent
            let (title, detail): (String, String) = switch name {
            case "VM": ("Swap", "Memory macOS has paged out to disk. It shrinks as apps quit or after a restart.")
            case "Preboot": ("Preboot volume", "Files the Mac needs to start up, kept per installed macOS version.")
            case "Update": ("Update volume", "Staging for software updates.")
            default: ("\(name) volume", "Another volume sharing this disk’s space.")
            }
            parts.append(Part(id: "volume:\(m.path)", kind: .volume, title: title, detail: detail, bytes: m.used))
        }
        let mountedUsed = siblings.reduce(Int64(0)) { $0 + $1.used }
        let unmounted = used - mountedUsed
        if unmounted >= 100_000_000 {
            parts.append(Part(id: "unmounted", kind: .unmounted, title: "Recovery and other volumes",
                              detail: "Volumes that share this disk but aren’t mounted, such as Recovery.",
                              bytes: unmounted))
        }
        if onVolume >= 100_000_000 {
            let folders = unreadable > 0 ? " Silt couldn’t open \(Fmt.count(unreadable)) folder\(unreadable == 1 ? "" : "s") here." : ""
            let left = excluded > 0 ? " It also holds the \(excluded == 1 ? "folder" : "\(excluded) folders") you chose not to scan." : ""
            parts.append(Part(id: "unreadable", kind: .unreadable,
                              title: excluded > 0 ? "Unreadable, system and unscanned data" : "Unreadable and system data",
                              detail: "Folders only macOS can read (Spotlight’s index, logs, other users’ files), snapshot data it doesn’t count as purgeable, and file-system bookkeeping.\(folders)\(left)",
                              bytes: onVolume))
        }
        parts.sort { $0.bytes > $1.bytes }
        return HiddenSpace(total: gap, parts: parts, snapshots: snapshots)
    }
}

/// Mounted file systems, with the APFS container each belongs to.
enum Mounts {
    struct Mount {
        let path: String
        let device: String
        /// "disk3" for /dev/disk3s5; nil if not an APFS volume.
        let container: String?
        var used: Int64 = 0
    }

    /// Fills in what the volume itself uses.
    static func withUsage(_ m: Mount) -> Mount {
        var m = m
        m.used = max(0, spaceUsed(m.path) ?? 0)
        return m
    }

    static func all() -> [Mount] {
        var buf: UnsafeMutablePointer<statfs>?
        let n = getmntinfo(&buf, MNT_NOWAIT)
        guard n > 0, let buf else { return [] }
        var out: [Mount] = []
        for i in 0..<Int(n) {
            var fs = buf[i]
            let path = withUnsafePointer(to: &fs.f_mntonname) { String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)) }
            let device = withUnsafePointer(to: &fs.f_mntfromname) { String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)) }
            let type = withUnsafePointer(to: &fs.f_fstypename) { String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)) }
            out.append(Mount(path: path, device: device, container: type == "apfs" ? container(of: device) : nil))
        }
        return out
    }

    /// Bytes an APFS volume itself uses (what `df` reports), or nil. statfs
    /// can't say: every volume in a container reports the container's space.
    private static func spaceUsed(_ path: String) -> Int64? {
        var al = attrlist()
        al.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        al.volattr = attrgroup_t(0x8000_0000) /* ATTR_VOL_INFO */ | attrgroup_t(ATTR_VOL_SPACEUSED)
        var buf = [UInt8](repeating: 0, count: 32)
        guard getattrlist(path, &al, &buf, buf.count, 0) == 0 else { return nil }
        return buf.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: Int64.self) }
    }

    /// "/dev/disk3s1s1" → "disk3".
    private static func container(of device: String) -> String? {
        guard device.hasPrefix("/dev/disk") else { return nil }
        let rest = device.dropFirst(5) // "disk3s1s1"
        guard let s = rest.dropFirst(4).firstIndex(of: "s") else { return nil }
        return String(rest[..<s])
    }
}

/// Local Time Machine snapshots, via `tmutil` (no special privileges needed).
enum LocalSnapshots {
    static func list(for path: String) -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
        p.arguments = ["listlocalsnapshots", path]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return [] }
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("com.apple.") }
            .sorted()
    }

    /// Deletes every local Time Machine snapshot of the volume mounted at
    /// `path` (no admin rights needed). The snapshots are listed before and
    /// after, so what's reported is what actually went, not the count shown
    /// when the user asked.
    static func deleteAll(on path: String) -> DeleteOutcome {
        let before = list(for: path)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
        p.arguments = ["deletelocalsnapshots", path]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return DeleteOutcome(deleted: 0, remaining: before.count, problem: error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return outcome(before: before, after: list(for: path), status: p.terminationStatus,
                       output: String(decoding: data, as: UTF8.self))
    }

    struct DeleteOutcome: Equatable {
        let deleted: Int
        /// Snapshots that were there before and still are.
        let remaining: Int
        let problem: String?
    }

    /// What a `tmutil deletelocalsnapshots` run did. It can print "Failed…"
    /// for some snapshots and still exit 0, so its output and the lists
    /// both count, not just its status.
    static func outcome(before: [String], after: [String], status: Int32, output: String) -> DeleteOutcome {
        let gone = Set(before).subtracting(after)
        let remaining = Set(before).intersection(after).count
        let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var problem = lines.first(where: { $0.hasPrefix("Failed") })
        if problem == nil, status != 0 { problem = lines.last ?? "tmutil stopped with status \(status)." }
        if problem == nil, remaining > 0 {
            problem = remaining == 1 ? "1 snapshot is still there." : "\(remaining) snapshots are still there."
        }
        return DeleteOutcome(deleted: gone.count, remaining: remaining, problem: problem)
    }

    /// "com.apple.TimeMachine.2026-09-26-223928.local" → a date.
    static func date(of name: String) -> Date? {
        let parts = name.split(separator: ".")
        guard let stamp = parts.first(where: { $0.count == 17 && $0.contains("-") }) else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f.date(from: String(stamp))
    }
}
