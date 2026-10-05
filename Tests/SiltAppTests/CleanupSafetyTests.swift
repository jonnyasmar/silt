import Foundation
import SiltCore
import Testing
@testable import Silt

/// What every destructive path promises: never into another volume, never
/// the last copy of a duplicate's contents, never a file that changed since
/// it was compared, and never rows nobody can see.

private func scratchRoot(_ prefix: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func live(_ root: URL) async -> Session {
    let s = await MainActor.run { Session(url: root, guardPrivateFolders: true, fresh: true) }
    #expect(await wait { s.phase == .live && s.canPark })
    return s
}

private func finish(_ s: Session) async {
    _ = await wait {
        guard s.canPark else { return false }
        s.close()
        return true
    }
}

private func cleanUp(_ root: URL) {
    Snapshots.discard(for: root)
    UserDefaults.standard.removeObject(forKey: "marks:" + root.path)
    try? FileManager.default.removeItem(at: root)
}

@discardableResult
private func run(_ tool: String, _ args: [String]) throws -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try p.run()
    p.waitUntilExit()
    return p.terminationStatus
}

// MARK: Other volumes

/// A volume mounted inside a scan shows as an empty folder. Deleting it would
/// empty the volume, so every path refuses it.
@Test func mountedVolumesAreNeverDeleted() async throws {
    let root = try scratchRoot("silt-mount")
    let images = try scratchRoot("silt-mount-image")
    let mount = root.appendingPathComponent("mounted")
    let image = images.appendingPathComponent("vol.dmg")
    try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("plain"), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: mount)
    try #require(try run("/usr/bin/hdiutil", ["create", "-size", "4m", "-fs", "HFS+", "-volname", "SiltTest",
                                               "-o", image.path]) == 0)
    try #require(try run("/usr/bin/hdiutil", ["attach", image.path, "-mountpoint", mount.path,
                                               "-nobrowse", "-noautoopen"]) == 0)
    defer {
        _ = try? run("/usr/bin/hdiutil", ["detach", mount.path, "-force"])
        cleanUp(root)
        try? FileManager.default.removeItem(at: images)
    }
    let precious = mount.appendingPathComponent("precious.txt")
    try Data("keep me".utf8).write(to: precious)

    #expect(Session.isVolumeRoot(mount.path))
    #expect(!Session.isVolumeRoot(root.appendingPathComponent("plain").path))
    #expect(!Session.isVolumeRoot(root.appendingPathComponent("link").path)) // the link itself is ours
    #expect(!Session.isVolumeRoot(precious.path))

    let s = await live(root)
    let ref = try #require(await MainActor.run { s.liveRef(path: mount.path) })

    await MainActor.run { s.deleteImmediately([ref], window: nil, confirmed: true) }
    await settle(1)
    #expect(FileManager.default.fileExists(atPath: precious.path))
    #expect(await MainActor.run { s.toast?.title.contains("won’t delete") } == true)

    await MainActor.run { s.moveToTrash([ref]) }
    await settle(1)
    #expect(FileManager.default.fileExists(atPath: precious.path))

    await MainActor.run {
        s.mark([ref], reason: "test")
        s.cleanUp(.delete)
    }
    await settle(1)
    #expect(FileManager.default.fileExists(atPath: precious.path))
    #expect(await MainActor.run { s.toast?.title } == "Nothing was removed")
    await finish(s)
}

// MARK: Duplicates

/// Identical files `names` under `root`, and the set a search would find.
@MainActor
private func copies(_ names: [String], in root: URL, session s: Session) throws -> DuplicateSet {
    let found: [DuplicateSet.Copy] = try names.map { n in
        let path = root.appendingPathComponent(n).path
        let st = try #require(FileStamp(path: path))
        return DuplicateSet.Copy(entry: s.tree.withLock { s.tree.lookup(path) }, path: path, stamp: st,
                                 family: StorageFamily(dev: st.dev, id: st.ino, isClone: false))
    }
    return DuplicateSet(size: found[0].stamp.size, copies: found)
}

private func writeCopies(_ names: [String], in root: URL) throws {
    for n in names {
        let url = root.appendingPathComponent(n)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: 16_384).write(to: url)
    }
}

private func surviving(_ names: [String], in root: URL) -> [String] {
    names.filter { FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) }
}

/// Every copy marked (say, after switching the keep rule and marking extras
/// again): cleanup removes all but one.
@Test func markingEveryCopyStillKeepsOne() async throws {
    let root = try scratchRoot("silt-dupes-all")
    defer { cleanUp(root) }
    let names = ["a/f.bin", "b/f.bin", "c/f.bin"]
    try writeCopies(names, in: root)
    await settle(1.5)
    let s = await live(root)

    await MainActor.run {
        let set = try! copies(names, in: root, session: s)
        s.mark(copies: set.copies, of: [set], reason: "Duplicate")
    }
    #expect(await MainActor.run { s.markedCount } == 3)
    await MainActor.run { s.cleanUp(.delete) }
    #expect(await wait { surviving(names, in: root).count == 1 && s.toast?.title.hasPrefix("Freed") == true })
    #expect(await MainActor.run { s.toast?.detail?.contains("last of its contents") } == true)
    await settle(0.5)
    #expect(surviving(names, in: root).count == 1)
    await finish(s)
}

/// The kept copy marked some other way (it's also an old large file): the
/// extras' marks see it going, so one of them stays.
@Test func keptCopyMarkedElsewhereLeavesAnExtra() async throws {
    let root = try scratchRoot("silt-dupes-keeper")
    defer { cleanUp(root) }
    let names = ["a/f.bin", "b/f.bin", "c/f.bin"]
    try writeCopies(names, in: root)
    await settle(1.5)
    let s = await live(root)

    await MainActor.run {
        let set = try! copies(names, in: root, session: s)
        s.mark(copies: Array(set.copies.dropFirst()), of: [set], reason: "Duplicate")
        if let keeper = s.liveRef(path: set.copies[0].path) { s.mark([keeper], reason: "Large files untouched for a year") }
    }
    #expect(await MainActor.run { s.markedCount } == 3)
    await MainActor.run { s.cleanUp(.delete) }
    #expect(await wait { surviving(names, in: root).count == 1 && s.toast?.title.hasPrefix("Freed") == true })
    #expect(!surviving(names, in: root).contains("a/f.bin")) // the plain mark went; an extra stayed
    await finish(s)
}

/// An extra edited after it was compared isn't a copy any more: it stays.
@Test func copyChangedSinceTheSearchIsLeftAlone() async throws {
    let root = try scratchRoot("silt-dupes-edit")
    defer { cleanUp(root) }
    let names = ["a/f.bin", "b/f.bin", "c/f.bin"]
    try writeCopies(names, in: root)
    await settle(1.5)
    let s = await live(root)

    await MainActor.run {
        let set = try! copies(names, in: root, session: s)
        s.mark(copies: Array(set.copies.dropFirst()), of: [set], reason: "Duplicate")
    }
    let edited = try FileHandle(forWritingTo: root.appendingPathComponent("b/f.bin"))
    try edited.seekToEnd()
    try edited.write(contentsOf: Data("my edits".utf8))
    try edited.close()
    await settle(1)

    await MainActor.run { s.cleanUp(.delete) }
    #expect(await wait { s.toast?.title.hasPrefix("Freed") == true })
    #expect(surviving(names, in: root) == ["a/f.bin", "b/f.bin"])
    #expect(await MainActor.run { s.toast?.detail?.contains("changed since") } == true)
    await finish(s)
}

/// The check travels with the mark through a relaunch.
@Test func lastCopyCheckSurvivesARelaunch() async throws {
    let root = try scratchRoot("silt-dupes-relaunch")
    defer { cleanUp(root) }
    let names = ["a/f.bin", "b/f.bin"]
    try writeCopies(names, in: root)
    await settle(1.5)

    let first = await live(root)
    await MainActor.run {
        let set = try! copies(names, in: root, session: first)
        first.mark(copies: set.copies, of: [set], reason: "Duplicate")
        first.flushMarks()
    }
    await finish(first)

    let s = await live(root)
    #expect(await wait { s.markedCount == 2 })
    await MainActor.run { s.cleanUp(.delete) }
    #expect(await wait { surviving(names, in: root).count == 1 && s.toast?.title.hasPrefix("Freed") == true })
    await settle(0.5)
    #expect(surviving(names, in: root).count == 1)
    await finish(s)
}

// MARK: Selection

/// A tree that leaves the screen takes its selection with it, unless a tree
/// that replaced it has already selected something of its own.
@Test func treeLeavingTakesItsSelection() async throws {
    let root = try scratchRoot("silt-selection")
    defer { cleanUp(root) }
    try writeCopies(["a.bin", "b.bin"], in: root)
    await settle(1.5)
    let s = await live(root)

    await MainActor.run {
        let tree = TreeController(session: s, source: .folder(s.focus))
        _ = tree.outline.numberOfRows
        tree.outline.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        #expect(s.selection.count == 1)
        tree.teardown()
        #expect(s.selection.isEmpty)

        let old = TreeController(session: s, source: .folder(s.focus))
        _ = old.outline.numberOfRows
        old.outline.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let replacement = TreeController(session: s, source: .folder(s.focus))
        _ = replacement.outline.numberOfRows
        replacement.outline.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        let picked = s.selection
        old.teardown()
        #expect(s.selection == picked)
        replacement.teardown()
    }
    await finish(s)
}

// MARK: What's called safe

/// Only a DerivedData folder Xcode made counts as build output: one beside a
/// project, or with Xcode's layout inside. The name alone isn't enough.
@Test func derivedDataNeedsXcodeEvidence() async throws {
    let root = try scratchRoot("silt-deriveddata")
    defer { cleanUp(root) }
    let fm = FileManager.default
    for dir in ["research/DerivedData", "app/Foo.xcodeproj", "app/DerivedData/Build",
                "loose/DerivedData/Build", "loose/DerivedData/Logs",
                "workspace/DerivedData/Foo-abcdef/ModuleCache.noindex"] {
        try fm.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true)
    }
    try Data("subject,score\n".utf8).write(to: root.appendingPathComponent("research/DerivedData/results.csv"))

    let tree = Tree(path: root.path)
    tree.startScan()
    defer { tree.stop() }
    #expect(await wait { tree.progress.idle && tree.progress.finished > 0 })
    func xcode(_ folder: String) -> Bool {
        tree.withLock {
            let i = tree.lookup(root.appendingPathComponent(folder + "/DerivedData").path)
            return i != NONE && Guide.isXcodeDerivedData(tree, tree.entry(i))
        }
    }
    #expect(!xcode("research"))
    #expect(xcode("app"))
    #expect(xcode("loose"))
    #expect(xcode("workspace"))
    let research = root.appendingPathComponent("research/DerivedData").path
    let guidance = tree.withLock {
        Guide.classify(tree: tree, entry: tree.lookup(research), name: "DerivedData", path: { research })
    }
    #expect(guidance == nil)
}

/// Even with dependency and build folders included, nothing inside a
/// version-control store is a duplicate candidate.
@Test func versionControlStoresAreNeverDuplicateCandidates() async throws {
    let root = try scratchRoot("silt-vcs")
    defer { cleanUp(root) }
    for path in ["repo/.git/lfs/objects/aa/blob", "repo/.hg/store/blob", "repo/model.bin"] {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 3, count: 1_200_000).write(to: url)
    }
    let tree = Tree(path: root.path)
    tree.startScan()
    defer { tree.stop() }
    #expect(await wait { tree.progress.idle && tree.progress.finished > 0 })
    let found = tree.filesAtLeast(1_000_000, skip: DuplicateFinder.alwaysSkipped, skipPackages: false, limit: 100)
    let names = tree.withLock { found.map { tree.path(of: $0) } }
    #expect(names == [root.appendingPathComponent("repo/model.bin").path])
}

