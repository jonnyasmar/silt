import Foundation

/// Where something sits, as far as cleanup advice goes. Build output is only
/// disposable in your own projects: folders with the same names inside an app
/// bundle, a package manager's install, or a tool's support files belong to
/// something that won't rebuild them, and deleting them breaks it.
enum Place: Equatable {
    /// Somewhere of yours: a project, a download, a document folder.
    case yours
    /// Inside an app or other bundle (named, e.g. "Cursor.app").
    case bundle(String)
    /// Part of macOS or an installed tool: `/opt`, `~/Library`, `~/.asdf`…
    case managed

    var isYours: Bool { self == .yours }

    private static let bundleExtensions: Set<String> = [
        "app", "framework", "bundle", "plugin", "appex", "xpc", "kext", "prefpane", "qlgenerator",
        "mdimporter", "saver", "systemextension", "xcframework", "docc", "photoslibrary", "musiclibrary",
        "tvlibrary", "component", "vst", "vst3", "aaxplugin",
    ]
    /// Top-level folders of a startup volume that belong to the system or to
    /// installed software.
    private static let systemRoots: Set<String> = [
        "System", "Library", "Applications", "usr", "opt", "private", "bin", "sbin", "cores", "nix",
    ]
    /// Folder names that only package managers and installers create.
    private static let installFolders: Set<String> = [
        "site-packages", "dist-packages", "Cellar", "Caskroom", "_tool", "libexec",
    ]

    /// Classifies the item at `path` (its own name doesn't count, so an app
    /// bundle itself is `.yours` if it sits somewhere of yours).
    static func of(_ path: String, home: String = NSHomeDirectory()) -> Place {
        let parts = path.split(separator: "/").map(String.init)
        let above = parts.dropLast()
        for p in above {
            let ext = (p as NSString).pathExtension.lowercased()
            if !ext.isEmpty, bundleExtensions.contains(ext) { return .bundle(p) }
        }
        if let first = above.first, systemRoots.contains(first) { return .managed }
        if above.contains(where: installFolders.contains) { return .managed }
        let homeParts = home.split(separator: "/").map(String.init)
        if above.count > homeParts.count, Array(above.prefix(homeParts.count)) == homeParts {
            let rest = above.dropFirst(homeParts.count)
            let next = rest.first!
            // ~/Library holds apps' own files (except the cloud-synced folders,
            // which hold yours); ~/.something is a tool's.
            if next == "Library" {
                let sub = rest.dropFirst().first
                return sub == "Mobile Documents" || sub == "CloudStorage" ? .yours : .managed
            }
            if next.hasPrefix(".") { return .managed }
        }
        return .yours
    }

    /// Why Silt won't call something here disposable.
    func caution(for what: String) -> String {
        switch self {
        case .yours: ""
        case .bundle(let name):
            "Part of \(name). Apps are signed, so changing what’s inside one can stop it from opening. To get this space back, remove the whole app."
        case .managed:
            "Part of an installed tool or of macOS, not one of your projects. Nothing will put \(what) back, and whatever uses it would break."
        }
    }
}
