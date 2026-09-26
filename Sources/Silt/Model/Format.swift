import Foundation

/// Hot-path formatting. These run for every visible cell on every tick, so
/// they avoid Foundation formatters.
enum Fmt {
    private static let units = ["B", "KB", "MB", "GB", "TB", "PB"]

    /// Decimal units, like Finder: 1 KB = 1000 bytes.
    static func bytes(_ value: Int64) -> String {
        if value < 1000 { return "\(max(value, 0)) B" }
        var v = Double(value)
        var unit = 0
        while v >= 999.95 && unit < units.count - 1 {
            v /= 1000
            unit += 1
        }
        return String(format: "%.1f %@", v, units[unit])
    }

    /// "84.0" and "GB" separately, for layouts that style the unit.
    static func bytesParts(_ value: Int64) -> (number: String, unit: String) {
        let s = bytes(value)
        guard let space = s.lastIndex(of: " ") else { return (s, "") }
        return (String(s[..<space]), String(s[s.index(after: space)...]))
    }

    static func count(_ n: Int) -> String {
        var s = String(n)
        var i = s.count - 3
        while i > 0 {
            s.insert(",", at: s.index(s.startIndex, offsetBy: i))
            i -= 3
        }
        return s
    }

    static func compactCount(_ n: Int) -> String {
        switch n {
        case ..<10_000: return count(n)
        case ..<1_000_000: return String(format: "%.0fK", Double(n) / 1000)
        default: return String(format: "%.1fM", Double(n) / 1_000_000)
        }
    }

    static func age(_ unix: UInt32, now: TimeInterval = Date().timeIntervalSince1970) -> String {
        if unix == 0 { return "—" }
        let d = now - TimeInterval(unix)
        switch d {
        case ..<60: return "just now"
        case ..<3600: return "\(Int(d / 60)) min ago"
        case ..<86400: return "\(Int(d / 3600)) hr ago"
        case ..<(86400 * 14): return plural(Int(d / 86400), "day")
        case ..<(86400 * 60): return plural(Int(d / (86400 * 7)), "wk")
        case ..<(86400 * 365): return plural(Int(d / (86400 * 30.44)), "mo")
        default: return plural(Int(d / (86400 * 365.25)), "yr")
        }
    }

    private static func plural(_ n: Int, _ unit: String) -> String {
        unit == "day" && n != 1 ? "\(n) days ago" : "\(n) \(unit) ago"
    }

    static func duration(_ seconds: Double) -> String {
        if seconds < 10 { return String(format: "%.1fs", seconds) }
        if seconds < 60 { return String(format: "%.0fs", seconds) }
        let m = Int(seconds) / 60, s = Int(seconds) % 60
        return "\(m)m \(s)s"
    }

    static func percent(_ fraction: Double) -> String {
        if fraction <= 0 { return "0%" }
        if fraction < 0.001 { return "<0.1%" }
        if fraction < 0.1 { return String(format: "%.1f%%", fraction * 100) }
        return String(format: "%.0f%%", fraction * 100)
    }
}
