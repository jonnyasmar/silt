import Foundation
import SiltCore

/// What Silt knows about a file or folder, from its name and surroundings:
/// a short tag for the tree, and a fuller explanation for the inspector.
struct Guidance: Equatable {
    enum Safety: Equatable {
        case safe     // rebuilt or re-downloaded on demand
        case review   // probably unneeded, but only you can say
        case keep     // leave it alone
    }

    let tag: String
    let title: String
    let detail: String
    let safety: Safety
}

enum Guide {
    /// Lock held. `name` is the entry's name; `path` is built only when a
    /// rule needs it.
    static func classify(tree: Tree, entry i: UInt32, name: String, path: () -> String) -> Guidance? {
        let e = tree.entry(i)
        if e.isDir {
            return folder(tree: tree, entry: e, name: name, path: path)
        }
        return file(name: name, path: path)
    }

    private static func has(_ tree: Tree, dir: UInt32, child: String) -> Bool {
        let d = tree.dir(dir)
        let want = Array(child.utf8)
        for k in d.first..<(d.first + d.count) {
            let c = tree.entry(k)
            if c.isRemoved || Int(c.name_len) != want.count { continue }
            if want.withUnsafeBufferPointer({ memcmp(silt_name_ptr(tree.raw, c.name), $0.baseAddress!, want.count) }) == 0 {
                return true
            }
        }
        return false
    }

    /// The install command the project's lockfile implies.
    private static func installCommand(_ tree: Tree, _ e: silt_entry) -> String {
        if sibling(tree, of: e, "pnpm-lock.yaml") { return "pnpm install" }
        if sibling(tree, of: e, "yarn.lock") { return "yarn install" }
        if sibling(tree, of: e, "bun.lockb") || sibling(tree, of: e, "bun.lock") { return "bun install" }
        return "npm install"
    }

    /// " The project last changed 3 months ago." — ignoring the build folder
    /// itself, so it says how dormant the project is.
    private static func projectNote(_ tree: Tree, _ e: silt_entry) -> String {
        guard e.parent != NONE else { return "" }
        let p = tree.dir(e.parent)
        var newest: UInt32 = 0
        for k in p.first..<(p.first + p.count) {
            let c = tree.entry(k)
            if c.isRemoved || (c.isDir && c.aux == e.aux) { continue }
            newest = max(newest, c.isDir ? tree.dir(c.aux).newest : c.aux)
        }
        guard newest > 0 else { return "" }
        let age = Date().timeIntervalSince1970 - TimeInterval(newest)
        if age > 90 * 86400 { return " The project hasn’t changed in \(Fmt.age(newest).replacingOccurrences(of: " ago", with: "")), so you may not need these soon." }
        return " The project last changed \(Fmt.age(newest))."
    }

    private static func sibling(_ tree: Tree, of e: silt_entry, _ name: String) -> Bool {
        e.parent != NONE && has(tree, dir: e.parent, child: name)
    }

    /// Advice for a project's build output or dependencies, which only holds
    /// in a project of yours: inside an app or an installed tool, the same
    /// names are part of software that won't rebuild them.
    private static func inProject(_ g: Guidance, _ place: Place, what: String) -> Guidance {
        guard !place.isYours else { return g }
        let title: String
        if case .bundle(let app) = place { title = "Part of \(app)" } else { title = "Part of an installed tool" }
        return Guidance(tag: "", title: title, detail: place.caution(for: what), safety: .keep)
    }

    private static func folder(tree: Tree, entry e: silt_entry, name: String, path: () -> String) -> Guidance? {
        let home = NSHomeDirectory()
        switch name {
        case "node_modules":
            let place = Place.of(path())
            let parent = e.parent == NONE ? "" : tree.name(of: tree.entry(tree.dirEntry(e.parent)))
            if place.isYours && (parent == "lib" || parent == "libexec") {
                // <prefix>/lib/node_modules: where `npm install -g` and Node
                // version managers put global packages, npm itself included.
                return Guidance(tag: "", title: "Global packages",
                                detail: "Packages installed with `npm install -g` or by a Node version manager, npm itself often among them. Removing this folder uninstalls them all.",
                                safety: .keep)
            }
            if sibling(tree, of: e, "package.json") {
                return inProject(Guidance(tag: "Dependencies", title: "JavaScript dependencies",
                                          detail: "Installed packages for the project next to it. `\(installCommand(tree, e))` puts them back."
                                              + projectNote(tree, e),
                                          safety: .safe), place, what: "these packages")
            }
            return inProject(Guidance(tag: "Leftover", title: "Dependencies without a project",
                                      detail: "There’s no package.json beside it, so it may be left over from a project that moved on, often after switching branches. Check before removing it: nothing will reinstall it.",
                                      safety: .review), place, what: "these packages")
        case "DerivedData":
            let p = path()
            let g = Guidance(tag: "Build output", title: "Xcode build output",
                             detail: "Intermediate build products. Xcode recreates them on the next build.", safety: .safe)
            return p.hasSuffix("/Library/Developer/Xcode/DerivedData") ? g : inProject(g, Place.of(p), what: "this folder")
        case ".build":
            if sibling(tree, of: e, "Package.swift") {
                return inProject(Guidance(tag: "Build output", title: "SwiftPM build output",
                                          detail: "Rebuilt by `swift build`.", safety: .safe), Place.of(path()), what: "this folder")
            }
        case "Pods":
            if sibling(tree, of: e, "Podfile") {
                return inProject(Guidance(tag: "Dependencies", title: "CocoaPods", detail: "Reinstalled by `pod install`.",
                                          safety: .safe), Place.of(path()), what: "these pods")
            }
        case ".gradle":
            if ["settings.gradle", "settings.gradle.kts", "build.gradle", "build.gradle.kts"].contains(where: { sibling(tree, of: e, $0) }) {
                return inProject(Guidance(tag: "Cache", title: "Gradle project cache",
                                          detail: "Per-project Gradle state, recreated on the next build.", safety: .safe),
                                 Place.of(path()), what: "this folder")
            }
        case ".next", ".nuxt", ".turbo", ".parcel-cache", ".svelte-kit", ".angular", "__pycache__", ".pytest_cache",
             ".mypy_cache", ".ruff_cache":
            return inProject(Guidance(tag: "Cache", title: "Build cache",
                                      detail: "Generated by your tools and recreated the next time they run.", safety: .safe),
                             Place.of(path()), what: "this folder")
        case ".venv", "venv":
            if has(tree, dir: e.aux, child: "pyvenv.cfg") {
                return inProject(Guidance(tag: "Environment", title: "Python virtual environment",
                                          detail: "Recreate it from your requirements or lockfile.", safety: .review),
                                 Place.of(path()), what: "this environment")
            }
        case ".git":
            return Guidance(tag: "History", title: "Git repository data",
                            detail: "Every commit and branch of this project. Deleting it erases the history; `git gc` can shrink it instead.",
                            safety: .keep)
        case "Caches":
            let p = path()
            if p == home + "/Library/Caches" || (p.hasPrefix(home + "/Library/Containers/") && p.hasSuffix("/Data/Library/Caches")) {
                return Guidance(tag: "Cache", title: "App caches",
                                detail: "Apps rebuild these as needed. Quit large apps before clearing them.", safety: .safe)
            }
            if p == "/Library/Caches" {
                return Guidance(tag: "Cache", title: "Shared caches",
                                detail: "Caches for every user and for system services. Some are rebuilt only slowly; clear them from the apps that own them.",
                                safety: .review)
            }
        case ".Trash", ".Trashes":
            return Guidance(tag: "Trash", title: "Trash",
                            detail: "Already deleted, but still using space until the Trash is emptied.", safety: .safe)
        case "Downloads" where path() == home + "/Downloads":
            return Guidance(tag: "", title: "Downloads",
                            detail: "Everything you've downloaded. Installers and archives here are usually safe to thin out.",
                            safety: .review)
        case "iOS DeviceSupport", "watchOS DeviceSupport", "tvOS DeviceSupport", "visionOS DeviceSupport":
            if path().hasPrefix(home + "/Library/Developer/Xcode/") {
                return Guidance(tag: "Cache", title: "Device support files",
                                detail: "Debug symbols Xcode copies from devices. Re-copied the next time you connect one.",
                                safety: .safe)
            }
        case "Archives" where path().hasSuffix("Developer/Xcode/Archives"):
            return Guidance(tag: "", title: "Xcode archives",
                            detail: "Past app builds. Keep any you might need for crash symbolication.", safety: .review)
        default:
            break
        }
        // Cargo target folders, wherever they live (build output even in a
        // tool's folder, but never inside an app).
        if has(tree, dir: e.aux, child: ".rustc_info.json") {
            let g = Guidance(tag: "Build output", title: "Rust build output",
                             detail: "A cargo target folder. The next `cargo build` recreates it, though a full rebuild can take a while."
                                 + (sibling(tree, of: e, "Cargo.toml") ? projectNote(tree, e) : ""),
                             safety: .safe)
            let place = Place.of(path())
            if case .bundle = place { return inProject(g, place, what: "this folder") }
            return g
        }
        let ext = (name as NSString).pathExtension.lowercased()
        if ext == "app" {
            let place = Place.of(path())
            if case .bundle = place {
                return Guidance(tag: "", title: "Helper app", detail: place.caution(for: "it"), safety: .keep)
            }
            return Guidance(tag: "", title: "Application",
                            detail: "Moving an app to the Trash uninstalls it. Its settings and caches in ~/Library may stay behind.",
                            safety: .review)
        }
        if ext == "xcarchive" {
            return Guidance(tag: "", title: "Xcode archive", detail: "A past app build.", safety: .review)
        }
        return nil
    }

    private static func file(name: String, path: () -> String) -> Guidance? {
        let ext = (name as NSString).pathExtension.lowercased()
        let g: Guidance
        switch ext {
        case "dmg", "pkg", "mpkg", "iso", "xip":
            g = Guidance(tag: "Installer", title: "Installer",
                         detail: "Once the software is installed, the installer is rarely needed again.", safety: .review)
        case "ipsw":
            g = Guidance(tag: "Firmware", title: "iPhone or iPad firmware",
                         detail: "Finder downloads it again when a device needs it.", safety: .safe)
        case "gguf", "safetensors", "ckpt", "pth", "onnx":
            g = Guidance(tag: "Model", title: "Model weights",
                         detail: "A local AI model. Delete it if you no longer run it; you can download it again.",
                         safety: .review)
        case "crash", "ips", "hprof":
            g = Guidance(tag: "Diagnostic", title: "Crash or memory dump",
                         detail: "Diagnostic output. Rarely needed after the problem is solved.", safety: .safe)
        default:
            return nil
        }
        // An installer or model shipped inside an app is part of the app.
        let place = Place.of(path())
        if case .bundle = place { return inProject(g, place, what: "it") }
        return g
    }
}
