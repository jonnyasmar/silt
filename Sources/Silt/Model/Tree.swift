import Foundation
import SiltCore

let NONE: UInt32 = 0xFFFF_FFFF

/// Swift face of a `silt_tree` plus the scanner that fills it.
///
/// Reads that may race a running scan go through `withLock`. Everything
/// inside the closure must be quick: the scanner's worker threads wait on the
/// same lock to commit their listings.
final class Tree: @unchecked Sendable {
    let raw: UnsafeMutablePointer<silt_tree>
    let rootPath: String
    private(set) var scanner: OpaquePointer?

    init(path: String) {
        rootPath = path
        raw = silt_tree_create(path)
    }

    /// Adopts a tree loaded from a snapshot.
    init(restored: UnsafeMutablePointer<silt_tree>, path: String) {
        rootPath = path
        raw = restored
    }

    deinit {
        if let scanner { silt_scanner_destroy(scanner) }
        silt_tree_destroy(raw)
    }

    /// Directory listing is syscall-bound, so more threads than cores helps
    /// keep the storage queue full.
    private static var threads: Int32 { Int32(max(8, ProcessInfo.processInfo.activeProcessorCount * 2)) }

    func startScan() {
        scanner = silt_scanner_start(raw, Self.threads)
    }

    /// For a restored tree: workers only, waiting for refreshes.
    func startIdle() {
        scanner = silt_scanner_start_idle(raw, Self.threads)
    }

    func stop() {
        if let scanner { silt_scanner_cancel(scanner) }
    }

    var progress: silt_progress {
        var p = silt_progress()
        if let scanner { silt_scanner_progress(scanner, &p) }
        return p
    }

    func refresh(dir: UInt32, deep: Bool) {
        if let scanner { silt_scanner_refresh(scanner, dir, deep) }
    }

    func remove(entry: UInt32) { silt_tree_remove(raw, entry) }

    @inline(__always) func withLock<T>(_ body: () throws -> T) rethrows -> T {
        silt_tree_lock(raw)
        defer { silt_tree_unlock(raw) }
        return try body()
    }

    var generation: UInt64 { withLock { raw.pointee.generation } }

    // MARK: Lock-held accessors

    @inline(__always) func entry(_ i: UInt32) -> silt_entry { silt_entry_at(raw, i).pointee }
    @inline(__always) func dir(_ d: UInt32) -> silt_dir { silt_dir_at(raw, d).pointee }
    @inline(__always) func dirEntry(_ d: UInt32) -> UInt32 { silt_dir_at(raw, d).pointee.entry }

    func name(of e: silt_entry) -> String {
        let buf = UnsafeBufferPointer(start: silt_name_ptr(raw, e.name), count: Int(e.name_len))
        return String(decoding: buf, as: UTF8.self)
    }

    func path(of entry: UInt32) -> String {
        withUnsafeTemporaryAllocation(of: CChar.self, capacity: 4096) { buf in
            let n = silt_path(raw, entry, buf.baseAddress!, 4096)
            return n > 0 ? String(cString: buf.baseAddress!) : ""
        }
    }

    func isLive(_ entry: UInt32) -> Bool { silt_is_live(raw, entry) }

    func lookup(_ path: String) -> UInt32 { silt_lookup(raw, path) }

    /// Live children of `dir`, sorted. Lock held.
    func children(of dir: UInt32, key: SortKey) -> [UInt32] {
        let count = Int(silt_dir_at(raw, dir).pointee.count)
        if count == 0 { return [] }
        return [UInt32](unsafeUninitializedCapacity: count) { buf, initialized in
            initialized = Int(silt_children_sorted(raw, dir, key.rawValue, buf.baseAddress!, UInt32(count)))
        }
    }

    // MARK: Queries (take the lock themselves)

    func topFiles(under dir: UInt32, limit: Int) -> [UInt32] {
        [UInt32](unsafeUninitializedCapacity: limit) { buf, n in
            n = Int(silt_top_files(raw, dir, buf.baseAddress!, UInt32(limit)))
        }
    }

    func topChildren(of dir: UInt32, limit: Int) -> [UInt32] {
        [UInt32](unsafeUninitializedCapacity: limit) { buf, n in
            n = Int(silt_top_children(raw, dir, buf.baseAddress!, UInt32(limit)))
        }
    }

    func search(_ needle: String, under dir: UInt32, limit: Int) -> [UInt32] {
        [UInt32](unsafeUninitializedCapacity: limit) { buf, n in
            n = Int(silt_search(raw, dir, needle, buf.baseAddress!, UInt32(limit)))
        }
    }

    func findDirs(named names: [String], under dir: UInt32, limit: Int) -> [(entry: UInt32, which: Int)] {
        withCStrings(names) { ptrs in
            var out = [UInt32](repeating: 0, count: limit)
            var which = [UInt32](repeating: 0, count: limit)
            let n = Int(silt_find_dirs(raw, dir, ptrs, UInt32(names.count), &out, &which, UInt32(limit)))
            return (0..<n).map { (out[$0], Int(which[$0])) }
        }
    }

    func findFiles(extensions: [String], under dir: UInt32, limit: Int) -> [(entry: UInt32, which: Int)] {
        withCStrings(extensions) { ptrs in
            var out = [UInt32](repeating: 0, count: limit)
            var which = [UInt32](repeating: 0, count: limit)
            let n = Int(silt_find_files(raw, dir, ptrs, UInt32(extensions.count), &out, &which, UInt32(limit)))
            return (0..<n).map { (out[$0], Int(which[$0])) }
        }
    }

    func staleFiles(under dir: UInt32, minSize: Int64, before: Date, limit: Int) -> [UInt32] {
        [UInt32](unsafeUninitializedCapacity: limit) { buf, n in
            n = Int(silt_stale_files(raw, dir, minSize, UInt32(before.timeIntervalSince1970), buf.baseAddress!, UInt32(limit)))
        }
    }

    struct ExtStat: Sendable {
        let ext: String
        let bytes: Int64
        let count: Int
    }

    func extensionStats(under dir: UInt32, limit: Int = 400) -> [ExtStat] {
        var out = [silt_ext_stat](repeating: silt_ext_stat(), count: limit)
        let n = Int(silt_ext_stats(raw, dir, &out, UInt32(limit)))
        return (0..<n).map { i in
            let ext = withUnsafeBytes(of: out[i].ext) { raw in
                String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            return ExtStat(ext: ext, bytes: Int64(out[i].bytes), count: Int(out[i].count))
        }
    }
}

enum SortKey: Int32, Sendable {
    case size = 0, name = 1, items = 2, modified = 3
}

private func withCStrings<R>(_ strings: [String], _ body: (UnsafePointer<UnsafePointer<CChar>?>) -> R) -> R {
    let dup = strings.map { strdup($0) }
    defer { dup.forEach { free($0) } }
    let ptrs = dup.map { UnsafePointer<CChar>($0) }
    return ptrs.withUnsafeBufferPointer { body($0.baseAddress!) }
}

extension silt_entry {
    var isDir: Bool { kind == UInt8(SILT_KIND_DIR) }
    var isRemoved: Bool { flags & UInt8(SILT_FLAG_REMOVED) != 0 }
    var isHidden: Bool { flags & UInt8(SILT_FLAG_HIDDEN) != 0 }
    var isDenied: Bool { flags & UInt8(SILT_FLAG_DENIED) != 0 }
    var isMount: Bool { flags & UInt8(SILT_FLAG_MOUNT) != 0 }
    var isHardLink: Bool { flags & UInt8(SILT_FLAG_HARDLINK) != 0 }
    var isDataless: Bool { flags & UInt8(SILT_FLAG_DATALESS) != 0 }
    var isSymlink: Bool { kind == UInt8(SILT_KIND_SYMLINK) }
}
