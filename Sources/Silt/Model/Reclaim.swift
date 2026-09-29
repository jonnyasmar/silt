import Foundation
import SiltCore

/// A group of things that are probably worth deleting, found from the
/// in-memory tree (no extra disk access).
struct Finding: Identifiable, Equatable, Sendable {
    enum Safety: Sendable { case safe, review }

    let id: String
    let title: String
    let detail: String
    let symbol: String
    let safety: Safety
    let entries: [UInt32]
    let bytes: Int64
    var isTrash = false
}

enum Reclaim {
    private struct Known {
        let path: String // relative to home
        let id: String
        let title: String
        let detail: String
        let symbol: String
        let safety: Finding.Safety
    }

    private static let known: [Known] = [
        Known(path: "Library/Caches", id: "caches", title: "App caches",
              detail: "Apps rebuild these as needed. Quit big apps first.", symbol: "shippingbox", safety: .safe),
        Known(path: "Library/Developer/Xcode/DerivedData", id: "deriveddata", title: "Xcode DerivedData",
              detail: "Build intermediates. Xcode recreates them on the next build.", symbol: "hammer", safety: .safe),
        Known(path: "Library/Developer/Xcode/iOS DeviceSupport", id: "devicesupport", title: "iOS device support",
              detail: "Debug symbols, re-copied when you connect a device.", symbol: "iphone", safety: .safe),
        Known(path: "Library/Developer/Xcode/watchOS DeviceSupport", id: "watchsupport", title: "watchOS device support",
              detail: "Debug symbols, re-copied when you connect a watch.", symbol: "applewatch", safety: .safe),
        Known(path: "Library/Developer/CoreSimulator/Caches", id: "simcaches", title: "Simulator caches",
              detail: "Dyld and runtime caches, regenerated on demand.", symbol: "iphone.gen3", safety: .safe),
        Known(path: "Library/Developer/Xcode/UserData/Previews", id: "previews", title: "SwiftUI preview builds",
              detail: "Rebuilt the next time a preview runs.", symbol: "rectangle.on.rectangle", safety: .safe),
        Known(path: ".npm/_cacache", id: "npm", title: "npm cache",
              detail: "Downloaded packages; npm fetches them again when needed.", symbol: "cube.box", safety: .safe),
        Known(path: "Library/pnpm/store", id: "pnpm", title: "pnpm store",
              detail: "Shared package store. `pnpm store prune` keeps what projects still use.",
              symbol: "cube.box", safety: .review),
        Known(path: ".gradle/caches", id: "gradle", title: "Gradle caches",
              detail: "Dependency and build caches, re-downloaded on demand.", symbol: "cube.box", safety: .safe),
        Known(path: ".cargo/registry", id: "cargo", title: "Cargo registry",
              detail: "Downloaded crates; Cargo refetches them.", symbol: "cube.box", safety: .safe),
        Known(path: "Library/Developer/CoreSimulator/Devices", id: "simulators", title: "Simulator devices",
              detail: "`xcrun simctl delete unavailable` removes ones for old runtimes.",
              symbol: "iphone.gen3", safety: .review),
        Known(path: "Library/Developer/Xcode/Archives", id: "archives", title: "Xcode archives",
              detail: "Old app builds. Keep any you need for crash symbolication.", symbol: "archivebox", safety: .review),
        Known(path: "Library/Containers/com.docker.docker/Data/vms", id: "docker", title: "Docker disk image",
              detail: "Holds every image and volume. Prune from Docker instead of deleting.",
              symbol: "shippingbox.circle", safety: .review),
        Known(path: "Library/Application Support/MobileSync/Backup", id: "iosbackup", title: "iPhone & iPad backups",
              detail: "Local device backups. Remove ones for devices you no longer have.",
              symbol: "externaldrive.badge.icloud", safety: .review),
        Known(path: "Library/Messages/Attachments", id: "messages", title: "Messages attachments",
              detail: "Photos and files from conversations.", symbol: "message", safety: .review),
        Known(path: ".ollama/models", id: "ollama", title: "Ollama models",
              detail: "Local language models. `ollama rm` the ones you don’t use.", symbol: "brain", safety: .review),
        Known(path: ".cache/huggingface", id: "huggingface", title: "Hugging Face cache",
              detail: "Downloaded models and datasets.", symbol: "brain", safety: .review),
        Known(path: ".lmstudio/models", id: "lmstudio", title: "LM Studio models",
              detail: "Local language models.", symbol: "brain", safety: .review),
        Known(path: "Downloads", id: "downloads", title: "Downloads",
              detail: "Everything you’ve downloaded. Usually safe to thin out.", symbol: "arrow.down.circle",
              safety: .review),
    ]

    /// Build output and dependencies, found by folder name. They count only in
    /// projects of yours (see `Place`), next to a file that proves the
    /// project is there to rebuild them.
    private struct Pattern {
        let name: String
        let markers: [String] // one of these must sit next to the folder
        let id: String
        let title: String
        let detail: String
        var safety: Finding.Safety = .safe
    }

    private static let js = ["package.json"]
    private static let patterns: [Pattern] = [
        Pattern(name: "node_modules", markers: js, id: "node_modules", title: "node_modules",
                detail: "JavaScript dependencies of your projects. Reinstall with your package manager."),
        Pattern(name: ".build", markers: ["Package.swift"], id: "swiftpm", title: "SwiftPM build output",
                detail: "`.build` folders next to Package.swift."),
        Pattern(name: "DerivedData", markers: [], id: "project-deriveddata", title: "Project DerivedData",
                detail: "Xcode build folders kept inside projects."),
        Pattern(name: "Pods", markers: ["Podfile"], id: "pods", title: "CocoaPods",
                detail: "Reinstalled by `pod install`."),
        Pattern(name: ".next", markers: js, id: "next", title: "Next.js build caches",
                detail: "`.next` folders; rebuilt by `next build`."),
        Pattern(name: ".turbo", markers: js, id: "turbo", title: "Turborepo caches", detail: "Local task caches."),
        Pattern(name: ".parcel-cache", markers: js, id: "parcel", title: "Parcel caches", detail: "Bundler caches."),
        Pattern(name: ".svelte-kit", markers: js, id: "sveltekit", title: "SvelteKit output",
                detail: "Generated on the next dev or build."),
        Pattern(name: ".gradle", markers: ["settings.gradle", "settings.gradle.kts", "build.gradle", "build.gradle.kts"],
                id: "project-gradle", title: "Project Gradle caches", detail: "Per-project Gradle state."),
        Pattern(name: ".venv", markers: ["pyproject.toml", "requirements.txt", "setup.py", "setup.cfg", "Pipfile",
                                         "uv.lock", "poetry.lock"],
                id: "venv", title: "Python virtualenvs",
                detail: "Environments for your Python projects. Recreate them from requirements or your lockfile.",
                safety: .review),
    ]

    private static let installerExts = ["dmg", "pkg", "mpkg", "iso", "xip"]
    private static let modelExts = ["gguf", "safetensors", "ckpt", "pth", "onnx", "mlpackage"]

    /// Runs off the main thread; everything goes through the tree's locking
    /// queries.
    static func analyze(tree: Tree, under dir: UInt32) -> [Finding] {
        var findings: [Finding] = []
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var claimed = Set<UInt32>()

        func sizes(_ entries: [UInt32]) -> Int64 {
            tree.withLock { entries.reduce(Int64(0)) { $0 + tree.entry($1).size } }
        }

        func within(_ entry: UInt32) -> Bool {
            tree.withLock {
                guard tree.isLive(entry) else { return false }
                var i = entry
                while true {
                    let e = tree.entry(i)
                    if e.isDir && e.aux == dir { return true }
                    if e.parent == NONE { return false }
                    i = tree.dirEntry(e.parent)
                }
            }
        }

        // Trash first: it's the one place where space is already "deleted".
        let trash = tree.withLock { tree.lookup(home + "/.Trash") }
        if trash != NONE, within(trash) {
            let kids = tree.withLock { tree.entry(trash).isDir ? tree.children(of: tree.entry(trash).aux, key: .size) : [] }
            let bytes = sizes([trash])
            if bytes > 0 {
                var f = Finding(id: "trash", title: "Trash", detail: "Already deleted, but still taking up space.",
                                symbol: "trash", safety: .safe, entries: kids, bytes: bytes)
                f.isTrash = true
                findings.append(f)
                claimed.insert(trash)
            }
        }

        for k in known {
            let e = tree.withLock { tree.lookup(home + "/" + k.path) }
            guard e != NONE, !claimed.contains(e), within(e) else { continue }
            let bytes = sizes([e])
            guard bytes > 10_000_000 else { continue }
            findings.append(Finding(id: k.id, title: k.title, detail: k.detail, symbol: k.symbol,
                                    safety: k.safety, entries: [e], bytes: bytes))
            claimed.insert(e)
        }

        let names = patterns.map(\.name)
        let matches = tree.findDirs(named: names, under: dir, limit: 20_000)
        var grouped: [Int: [UInt32]] = [:]
        var leftoverModules: [UInt32] = []
        tree.withLock {
            var repos: [UInt32: Bool] = [:]
            for m in matches {
                // Skip anything inside a known location we already listed.
                if isInside(tree, m.entry, claimed: claimed) { continue }
                let p = patterns[m.which]
                let path = tree.path(of: m.entry)
                // The same names inside an app or an installed tool (Homebrew,
                // asdf, an Electron app's runtime) are part of that software.
                guard Place.of(path, home: home).isYours else { continue }
                let parent = (path as NSString).deletingLastPathComponent
                if p.name == "node_modules" {
                    // <prefix>/lib/node_modules holds global packages.
                    let parentName = (parent as NSString).lastPathComponent
                    if parentName == "lib" || parentName == "libexec" { continue }
                }
                let marked = p.markers.isEmpty || p.markers.contains { tree.lookup(parent + "/" + $0) != NONE }
                if marked {
                    grouped[m.which, default: []].append(m.entry)
                } else if p.name == "node_modules", inRepository(tree, tree.entry(m.entry).parent, cache: &repos) {
                    // A project that no longer has a package.json, usually after
                    // switching branches. Only worth a look: nothing reinstalls it.
                    leftoverModules.append(m.entry)
                }
            }
        }
        for (which, entries) in grouped {
            let p = patterns[which]
            let bytes = sizes(entries)
            guard bytes > 50_000_000 else { continue }
            findings.append(Finding(id: p.id, title: p.title, detail: p.detail, symbol: "hammer",
                                    safety: p.safety, entries: entries, bytes: bytes))
        }

        let leftoverBytes = sizes(leftoverModules)
        if leftoverBytes > 20_000_000 {
            findings.append(Finding(id: "node-leftover", title: "node_modules without a package.json",
                                    detail: "In your repositories, but with no `package.json` beside them: often left behind after switching branches. Check each one; nothing will reinstall them.",
                                    symbol: "shippingbox", safety: .review, entries: leftoverModules,
                                    bytes: leftoverBytes))
        }

        // Rust build output wherever it lives: `.rustc_info.json` marks the root
        // of a cargo target dir, even one kept on another volume and reached
        // through a `target` symlink. If no project contains it or links to
        // it, it's orphaned (often left behind by a deleted worktree).
        // One exact-name pass finds both the markers and any `target` symlink
        // inside the scan (the match ignores case; these checks don't).
        let cap = 65_536
        let named = tree.findNamed(["target", ".rustc_info.json"], under: dir, limit: cap)
        let (linkPaths, infos): ([String], [UInt32]) = tree.withLock {
            var links: [String] = [], infos: [UInt32] = []
            for m in named {
                let e = tree.entry(m.entry)
                if m.which == 0, e.isSymlink, tree.name(of: e) == "target" {
                    links.append(tree.path(of: m.entry))
                } else if m.which == 1, !e.isDir, tree.name(of: e) == ".rustc_info.json" {
                    infos.append(m.entry)
                }
            }
            return (links, infos)
        }
        // Code folders the scan doesn't reach have their links read from disk.
        // If the search hit its cap, the smallest matches (symlinks among
        // them) were left out: read every code folder's links from disk, so a
        // linked target isn't taken for an orphan.
        var links = targetLinks(outside: named.count >= cap ? nil : tree, under: dir)
        for p in linkPaths {
            if let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: p) {
                let base = (p as NSString).deletingLastPathComponent
                let absolute = dest.hasPrefix("/") ? dest : (base as NSString).appendingPathComponent(dest)
                links.insert(URL(fileURLWithPath: absolute).standardizedFileURL.resolvingSymlinksInPath().path)
            }
        }
        var linkedRust: [UInt32] = [], orphanedRust: [UInt32] = []
        tree.withLock {
            for f in infos {
                let e = tree.entry(f)
                guard e.parent != NONE else { continue }
                let root = tree.dirEntry(e.parent)
                guard tree.isLive(root), !claimed.contains(root), !isInside(tree, root, claimed: claimed) else { continue }
                let path = tree.path(of: root)
                if case .bundle = Place.of(path, home: home) { continue }
                let parent = (path as NSString).deletingLastPathComponent
                let inProject = tree.lookup(parent + "/Cargo.toml") != NONE
                if inProject || links.contains(path) { linkedRust.append(root) } else { orphanedRust.append(root) }
            }
        }
        let orphanedRustBytes = sizes(orphanedRust)
        if orphanedRustBytes > 20_000_000 {
            findings.append(Finding(id: "rust-orphaned", title: "Rust build output with no project",
                                    detail: "Cargo target folders no project Silt could find links to, often left by deleted worktrees. At worst, deleting one costs a rebuild.",
                                    symbol: "hammer", safety: .safe, entries: orphanedRust, bytes: orphanedRustBytes))
        }
        let linkedRustBytes = sizes(linkedRust)
        if linkedRustBytes > 50_000_000 {
            findings.append(Finding(id: "rust-target", title: "Rust build output",
                                    detail: "Cargo target folders. The next `cargo build` recreates them, which can take a while.",
                                    symbol: "hammer", safety: .safe, entries: linkedRust, bytes: linkedRustBytes))
        }

        // Files only you put somewhere: an installer inside an app, or a
        // system asset nobody has touched in a year, is part of that software.
        func yours(_ e: UInt32) -> Bool {
            tree.withLock { !isInside(tree, e, claimed: claimed) && Place.of(tree.path(of: e), home: home).isYours }
        }
        let installers = tree.findFiles(extensions: installerExts, under: dir, limit: 2_000)
            .map(\.entry).filter(yours)
        let installerBytes = sizes(installers)
        if installerBytes > 50_000_000 {
            findings.append(Finding(id: "installers", title: "Installers & disk images",
                                    detail: "DMGs and packages you’ve probably already installed.",
                                    symbol: "opticaldiscdrive", safety: .review, entries: installers,
                                    bytes: installerBytes))
        }

        let models = tree.findFiles(extensions: modelExts, under: dir, limit: 2_000)
            .map(\.entry).filter(yours)
        let modelBytes = sizes(models)
        if modelBytes > 200_000_000 {
            findings.append(Finding(id: "models", title: "Model weights",
                                    detail: "Local AI model files found in this scan.",
                                    symbol: "brain", safety: .review, entries: models, bytes: modelBytes))
        }

        let yearAgo = Date().addingTimeInterval(-365 * 86400)
        let stale = tree.staleFiles(under: dir, minSize: 250_000_000, before: yearAgo, limit: 500)
            .filter(yours)
        let staleBytes = sizes(stale)
        if staleBytes > 0 {
            findings.append(Finding(id: "stale", title: "Large files untouched for a year",
                                    detail: "Over 250 MB and not modified in 12 months.",
                                    symbol: "clock.arrow.circlepath", safety: .review, entries: stale,
                                    bytes: staleBytes))
        }

        findings = splitDormant(tree: tree, findings)
        return findings.sorted { a, b in
            if a.isTrash != b.isTrash { return a.isTrash }
            if (a.id == "dormant") != (b.id == "dormant") { return a.id == "dormant" }
            return a.bytes > b.bytes
        }
    }

    private static let buildFindings: Set<String> = [
        "node_modules", "rust-target", "swiftpm", "project-deriveddata", "pods", "next", "turbo", "parcel",
        "sveltekit", "project-gradle",
    ]

    /// Build output whose project hasn't been touched in three months is the
    /// space you'll miss least: it moves out of its own group into one that
    /// leads the list.
    private static func splitDormant(tree: Tree, _ findings: [Finding]) -> [Finding] {
        let cutoff = UInt32(Date().addingTimeInterval(-90 * 86400).timeIntervalSince1970)
        var dormant: [UInt32] = []
        var projects = Set<UInt32>()
        var out: [Finding] = []
        tree.withLock {
            for f in findings {
                guard buildFindings.contains(f.id) else {
                    out.append(f)
                    continue
                }
                var keep: [UInt32] = []
                for i in f.entries where tree.isLive(i) {
                    let e = tree.entry(i)
                    guard e.parent != NONE else { continue }
                    // The project's own last change, ignoring the build folder.
                    let p = tree.dir(e.parent)
                    var newest: UInt32 = 0
                    for k in p.first..<(p.first + p.count) where k != i {
                        let c = tree.entry(k)
                        if c.isRemoved { continue }
                        let m = c.isDir ? tree.dir(c.aux).newest : c.aux
                        newest = max(newest, m)
                    }
                    if newest > 0 && newest < cutoff {
                        dormant.append(i)
                        projects.insert(e.parent)
                    } else {
                        keep.append(i)
                    }
                }
                let bytes = keep.reduce(Int64(0)) { $0 + tree.entry($1).size }
                if bytes > 20_000_000 {
                    out.append(Finding(id: f.id, title: f.title, detail: f.detail, symbol: f.symbol, safety: f.safety,
                                       entries: keep, bytes: bytes))
                }
            }
        }
        let bytes = tree.withLock { dormant.reduce(Int64(0)) { $0 + tree.entry($1).size } }
        if bytes > 20_000_000 {
            out.append(Finding(id: "dormant", title: "Build output in dormant projects",
                               detail: "\(projects.count) \(projects.count == 1 ? "project" : "projects") untouched for 3+ months. Their dependencies and build folders come back with one install or build if you return.",
                               symbol: "moon.zzz", safety: .safe, entries: dormant, bytes: bytes))
        }
        return out
    }

    /// The usual places people keep code, under the home folder.
    private static let codeFolders = ["dev", "Developer", "Projects", "projects", "code", "Code", "src", "work",
                                      "repos", "git", "GitHub"]

    /// Where projects' `target` symlinks point, for the usual places people
    /// keep code. Lets a target folder on another volume be recognized as
    /// still in use. Folders the scan has listed under `dir` are skipped:
    /// the in-tree search already sees their links.
    /// With no tree, every code folder is read.
    static func targetLinks(outside tree: Tree?, under dir: UInt32) -> Set<String> {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let roots = codeFolders.map { home + "/" + $0 }
        let inside: Set<String> = tree.map { tree in tree.withLock {
            Set(roots.filter { root in
                let i = tree.lookup(root)
                guard i != NONE, tree.isLive(i) else { return false }
                let e = tree.entry(i)
                guard e.isDir, !e.isMount, tree.dir(e.aux).state & UInt32(SILT_DIR_LISTED) != 0 else { return false }
                var d = e.aux
                while true {
                    if d == dir { return true }
                    let parent = tree.entry(tree.dirEntry(d)).parent
                    if parent == NONE { return false }
                    d = parent
                }
            })
        } } ?? []
        var out = Set<String>()
        for root in roots where !inside.contains(root) { out.formUnion(linkCache.links(under: root)) }
        return out
    }

    /// Each code folder's links, read at most every ten minutes: reading them
    /// means a readlink per project, thousands on a big `~/dev`.
    private static let linkCache = LinkCache()

    private final class LinkCache: @unchecked Sendable {
        private let lock = NSLock()
        private var known: [String: (at: TimeInterval, links: Set<String>)] = [:]
        private static let lifetime: TimeInterval = 600

        func links(under root: String) -> Set<String> {
            let now = ProcessInfo.processInfo.systemUptime
            lock.lock()
            let hit = known[root]
            lock.unlock()
            if let hit, now - hit.at < Self.lifetime { return hit.links }
            let links = Self.read(root)
            lock.lock()
            known[root] = (now, links)
            lock.unlock()
            return links
        }

        private static func read(_ base: String) -> Set<String> {
            let fm = FileManager.default
            var out = Set<String>()
            func check(_ project: String) {
                let link = project + "/target"
                guard let dest = try? fm.destinationOfSymbolicLink(atPath: link) else { return }
                let absolute = dest.hasPrefix("/") ? dest : (project as NSString).appendingPathComponent(dest)
                out.insert(URL(fileURLWithPath: absolute).standardizedFileURL.resolvingSymlinksInPath().path)
            }
            guard let kids = try? fm.contentsOfDirectory(atPath: base) else { return out }
            for k in kids {
                let project = base + "/" + k
                check(project)
                // One level deeper for org/repo layouts.
                if let inner = try? fm.contentsOfDirectory(atPath: project), inner.count < 200 {
                    for i in inner { check(project + "/" + i) }
                }
            }
            return out
        }
    }

    /// Lock held. True if folder `dir` or one above it holds a `.git` (a
    /// folder, or a file in a git worktree). Answers are cached per folder.
    private static func inRepository(_ tree: Tree, _ dir: UInt32, cache: inout [UInt32: Bool]) -> Bool {
        var chain: [UInt32] = []
        var d = dir
        var found = false
        while d != NONE {
            if let known = cache[d] {
                found = known
                break
            }
            chain.append(d)
            let run = tree.dir(d)
            let hasGit = (run.first..<(run.first + run.count)).contains { k in
                let c = tree.entry(k)
                return !c.isRemoved && c.name_len == 4 && tree.name(of: c) == ".git"
            }
            if hasGit {
                found = true
                break
            }
            d = tree.entry(tree.dirEntry(d)).parent
        }
        for c in chain { cache[c] = found }
        return found
    }

    /// Lock held. True if any ancestor of `entry` is in `claimed`.
    private static func isInside(_ tree: Tree, _ entry: UInt32, claimed: Set<UInt32>) -> Bool {
        guard !claimed.isEmpty else { return false }
        var parent = tree.entry(entry).parent
        while parent != NONE {
            let i = tree.dirEntry(parent)
            if claimed.contains(i) { return true }
            parent = tree.entry(i).parent
        }
        return false
    }
}
