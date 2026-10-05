import Foundation
import Observation

/// How Silt keeps one folder (and everything in it) up to date, overriding
/// what it would do on its own.
enum FolderRule: String, CaseIterable, Identifiable {
    case live, slow, paused, excluded

    var id: String { rawValue }

    /// The menu item.
    var title: String {
        switch self {
        case .live: "Live"
        case .slow: "Slowly"
        case .paused: "Paused"
        case .excluded: "Don’t Scan"
        }
    }

    /// The tag on its row.
    var tag: String {
        switch self {
        case .live: "Live"
        case .slow: "Slow"
        case .paused: "Paused"
        case .excluded: "Not scanned"
        }
    }

    var symbol: String {
        switch self {
        case .live: "bolt"
        case .slow: "tortoise"
        case .paused: "pause.circle"
        case .excluded: "eye.slash"
        }
    }

    var detail: String {
        switch self {
        case .live: "Updates the moment anything changes, even if it changes constantly."
        case .slow: "Updates at most once a minute."
        case .paused: "Updates only when you open it or choose Update Now."
        case .excluded: "Left out of the scan entirely. Its size isn’t counted."
        }
    }
}

extension Notification.Name {
    /// Folder rules changed: sessions re-apply them.
    static let siltFolderRulesChanged = Notification.Name("SiltFolderRulesChanged")
}

/// The folder rules, app-wide, by absolute path. A rule covers the folder
/// and everything inside it; the nearest one wins.
@MainActor
@Observable
final class FolderRules {
    static let shared = FolderRules()

    private(set) var rules: [String: FolderRule]
    private static let key = "folderRules"

    private init() {
        let saved = UserDefaults.standard.dictionary(forKey: Self.key) as? [String: String] ?? [:]
        rules = saved.compactMapValues(FolderRule.init)
    }

    /// Sets `path`'s rule; nil goes back to what Silt does on its own.
    func set(_ rule: FolderRule?, for path: String) {
        guard rules[path] != rule else { return }
        rules[path] = rule
        UserDefaults.standard.set(rules.mapValues(\.rawValue), forKey: Self.key)
        NotificationCenter.default.post(name: .siltFolderRulesChanged, object: nil)
    }

    /// The rule covering `path`, and the folder it was set on.
    func rule(for path: String) -> (path: String, rule: FolderRule)? {
        guard !rules.isEmpty else { return nil }
        var p = path
        while true {
            if let r = rules[p] { return (p, r) }
            guard p.count > 1 else { return nil }
            p = (p as NSString).deletingLastPathComponent
        }
    }

    /// Folders left out, sorted.
    var excluded: [String] { rules.filter { $0.value == .excluded }.keys.sorted() }
}
