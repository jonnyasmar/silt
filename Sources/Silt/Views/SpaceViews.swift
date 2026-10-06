import AppKit
import SwiftUI

/// Where a volume's space is: available now, being removed, in the Trash,
/// marked, and what local snapshots still hold of what Silt removed. Every
/// figure says what it can and can't promise.
struct SpacePopover: View {
    let session: Session
    /// The window the popover's dialogs belong to (not the popover's own).
    var window: NSWindow?
    var reviewCleanup: () -> Void = {}
    var done: () -> Void = {}
    @State private var trash: Session.TrashReading?
    @State private var markedSplit: SpaceSplit?

    var body: some View {
        let ledger = session.ledger
        VStack(alignment: .leading, spacing: 14) {
            available
            if !ledger.removing.isEmpty { removing(ledger.removing) }
            trashRow
            if session.markedBytes > 0 { marked }
            if ledger.held.total > 0 { held(ledger.held.total) }
            if ledger.freed > 0 {
                SpaceRow(symbol: "checkmark.circle", tint: .green, title: "Given back",
                         amount: ledger.freed,
                         detail: "What Silt’s removals here have freed since it opened, counting held space as its snapshots go.")
            }
            footer(ledger)
        }
        .padding(16)
        .frame(width: 360)
        // The Trash is measured on disk, again every few seconds while open.
        .task {
            while !Task.isCancelled {
                trash = await session.measureTrash()
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .task(id: session.markedBytes) {
            markedSplit = session.markedBytes > 0 ? await session.estimateMarked() : nil
        }
    }

    @ViewBuilder
    private var available: some View {
        if let cap = session.capacity {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(volumeName)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Spacer()
                    Text("\(Fmt.bytes(cap.total)) disk")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    let parts = Fmt.bytesParts(cap.available)
                    Text(parts.number)
                        .font(.system(size: 26, weight: .semibold, design: .rounded).monospacedDigit())
                        .contentTransition(.numericText())
                    Text("\(parts.unit) available")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                let parts = SpaceBar.Parts(capacity: cap, trash: trashBytes, held: session.ledger.held.total,
                                           marked: session.markedBytes)
                SpaceBar(parts: parts)
                    .frame(height: 8)
                    .padding(.vertical, 2)
                SpaceLegend(parts: parts)
                let purgeable = max(0, cap.available - cap.free)
                Text(purgeable >= 100_000_000
                     ? "\(Fmt.bytes(cap.free)) is free right now. macOS clears the other \(Fmt.bytes(purgeable)) (local snapshots and caches it can rebuild) whenever it needs room."
                     : "All of it is free right now.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var trashBytes: Int64 {
        if case .measured(let split) = trash { return split.measured }
        return 0
    }

    /// What free space would reach: emptying the Trash gives back at least
    /// what no snapshot holds, and the rest (with what's already held of
    /// Silt's removals) once the snapshots go. In free space, not available:
    /// macOS may already count snapshot space as available.
    private var projection: String? {
        guard let cap = session.capacity else { return nil }
        if case .measured(let split) = trash { return Self.projection(free: cap.free, trash: split, held: session.ledger.held.total) }
        return Self.projection(free: cap.free, trash: nil, held: session.ledger.held.total)
    }

    static func projection(free: Int64, trash: SpaceSplit?, held: Int64) -> String? {
        var now: Int64 = 0, later: Int64 = held
        let trashIn = trash.map { $0.known && $0.measured > 0 } ?? false
        if let trash, trashIn {
            now = trash.freesNow
            later += trash.heldBytes
        }
        guard now + later >= 100_000_000 else { return nil }
        let soon = Fmt.bytes(free + now), eventually = Fmt.bytes(free + now + later)
        if now > 0, later > 0 {
            return "Emptying the Trash would bring free space to at least \(soon), and up to \(eventually) once local snapshots let go."
        }
        if now > 0 { return "Emptying the Trash would bring free space to at least \(soon)." }
        return "Once local snapshots let go\(trashIn ? " (and the Trash is emptied)" : ""), free space would reach up to \(eventually)."
    }

    /// The figures are the volume's, whatever folder this scan is of.
    private var volumeName: String {
        (try? session.url.resourceValues(forKeys: [.volumeLocalizedNameKey]))?.volumeLocalizedName ?? session.title
    }

    private func removing(_ r: SpaceLedger.Removing) -> some View {
        let moving = r.items - r.deleting
        var lines: [String] = []
        if r.deleting > 0 { lines.append(r.deleting == 1 ? "Deleting 1 item" : "Deleting \(r.deleting) items") }
        if moving > 0 { lines.append(moving == 1 ? "moving 1 to the Trash" : "moving \(moving) to the Trash") }
        let title = lines.joined(separator: ", ").capitalizedFirstLetter
        let left = r.deletingLeft + (r.bytes - r.deletingBytes)
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "hourglass")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title).font(.system(size: 12, weight: .medium))
                    Spacer()
                    Text("\(Fmt.bytes(left)) to go")
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
                if let f = r.fractionDeleted, r.deleting > 0 {
                    ProgressView(value: f)
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                }
                if moving > 0 && r.deleting == 0 {
                    Text("Moving to the Trash frees nothing until it’s emptied.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var trashRow: some View {
        switch trash {
        case .measured(let split) where split.measured > 0:
            SpaceRow(symbol: "trash", tint: Brand.color, title: "In the Trash", amount: split.measured,
                     detail: Self.prefixed("Emptying it: ", split.summary(done: false))) {
                Button("Empty Trash…") {
                    done()
                    session.emptyTrash(window: window)
                }
            }
        case .needsAccess:
            SpaceRow(symbol: "trash", tint: .orange, title: "In the Trash", amount: nil,
                     detail: "Silt needs Full Disk Access to see inside the Trash.") {
                Button("Open Settings") { FullDiskAccess.openSettings() }
            }
        default:
            EmptyView()
        }
    }

    /// "Emptying it: at least …", or nothing to add.
    private static func prefixed(_ lead: String, _ summary: String) -> String {
        summary.isEmpty ? "" : lead + summary.lowercasedFirstLetter
    }

    private var marked: some View {
        SpaceRow(symbol: "checklist", tint: Brand.color, title: "Marked for cleanup", amount: session.markedBytes,
                 detail: markedSplit.map { Self.prefixed("Deleting it: ", $0.summary(done: false)) }
                     ?? "Working out what deleting it gives back…") {
            Button("Review…") {
                done()
                reviewCleanup()
            }
        }
    }

    private func held(_ bytes: Int64) -> some View {
        SpaceRow(symbol: "clock.badge.checkmark", tint: .secondary, title: "Held by local snapshots", amount: bytes,
                 detail: heldDetail) {
            Button("Delete the snapshots now…") {
                done()
                session.deleteLocalSnapshots(window: window)
            }
            .buttonStyle(.link)
            .help("Frees it now, but you lose those Time Machine restore points")
        }
    }

    /// When held space comes back can't be promised: only when every
    /// snapshot holding it is under a day old is "usually within a day" fair
    /// (Time Machine keeps the one from your last backup longer).
    private var heldDetail: String {
        let ledger = session.ledger
        let created = Dictionary((ledger.listing?.snapshots ?? []).map { ($0.name, $0.created) }) { a, _ in a }
        let young = ledger.held.holders.allSatisfy { name in
            created[name].map { Date().timeIntervalSince($0) < 86400 } ?? false
        }
        return young
            ? "Part of what Silt removed. It comes back as Time Machine lets these snapshots go, usually within a day (sooner if macOS needs room)."
            : "Part of what Silt removed. It comes back once those snapshots go: Time Machine keeps the one from your last backup until the next backup, or until macOS needs room."
    }

    @ViewBuilder
    private func footer(_ ledger: SpaceLedger) -> some View {
        if let projection {
            Text(projection)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        let note: String? = if SpaceVolume.snapshotMount(for: session.url.path) == nil {
            "On a network volume, Silt can’t tell what the server keeps, so what removing frees can’t be worked out."
        } else if ledger.listingFailed {
            "Silt couldn’t list this volume’s snapshots, so what removing frees can’t be worked out."
        } else if let l = ledger.listing, !l.estimable {
            "This volume has snapshots Silt can’t reason about (made by another app), so what removing frees can’t be worked out."
        } else if let l = ledger.listing {
            l.snapshots.isEmpty ? "No local snapshots: what you delete comes back right away (copies that share blocks aside)."
                : l.snapshots.count == 1 ? "1 local Time Machine snapshot on this volume."
                : "\(l.snapshots.count) local Time Machine snapshots on this volume."
        } else {
            nil
        }
        if let note {
            Divider()
            Text(note)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// One line of the ledger: what, how much, why, and what to do about it.
private struct SpaceRow<Action: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let amount: Int64?
    let detail: String
    @ViewBuilder var action: () -> Action

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.system(size: 12, weight: .medium))
                    Spacer()
                    if let amount {
                        Text(Fmt.bytes(amount))
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                            .contentTransition(.numericText())
                    }
                }
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                action()
                    .controlSize(.small)
                    .padding(.top, 2)
            }
        }
    }
}

extension SpaceRow where Action == EmptyView {
    init(symbol: String, tint: Color, title: String, amount: Int64?, detail: String) {
        self.init(symbol: symbol, tint: tint, title: title, amount: amount, detail: detail) { EmptyView() }
    }
}

/// A volume's space as one bar, in what's actually on disk: files, the
/// Trash, what snapshots hold of Silt's removals, what macOS can purge, and
/// what's free. The last two together are what's available. Marked items are
/// hatched at the end of the files.
struct SpaceBar: View {
    struct Parts: Equatable {
        var files: Int64
        var trash: Int64
        var held: Int64
        var purgeable: Int64
        var free: Int64
        var marked: Int64
        var total: Int64

        init(capacity cap: Capacity, trash: Int64 = 0, held: Int64 = 0, marked: Int64 = 0) {
            total = max(cap.total, 1)
            free = max(0, cap.free)
            purgeable = max(0, cap.available - cap.free)
            // What's left of what's used; snapshot space macOS already counts
            // as purgeable may also be in `held`, so it never goes negative.
            let rest = max(0, cap.total - free - purgeable)
            self.trash = min(trash, rest)
            self.held = min(held, rest - self.trash)
            files = rest - self.trash - self.held
            self.marked = min(marked, files)
        }

        var nearlyFull: Bool { Double(free + purgeable) / Double(total) < 0.1 }
    }

    let parts: Parts

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let x = { (bytes: Int64) in w * CGFloat(Double(bytes) / Double(parts.total)) }
            let files = x(parts.files), trash = x(parts.trash), held = x(parts.held), purge = x(parts.purgeable)
            let color = parts.nearlyFull ? Color.orange : Brand.color
            ZStack(alignment: .leading) {
                Rectangle().fill(.quaternary)
                Rectangle().fill(color).frame(width: files)
                if parts.marked > 0 {
                    let m = min(files, max(1, x(parts.marked)))
                    Stripes().fill(Color.white.opacity(0.55)).frame(width: m).offset(x: files - m)
                }
                Rectangle().fill(color.opacity(0.55)).frame(width: trash).offset(x: files)
                ZStack {
                    Rectangle().fill(Color.secondary.opacity(0.45))
                    Stripes().fill(Color.white.opacity(0.35))
                }
                .frame(width: held).offset(x: files + trash)
                Rectangle().fill(color.opacity(0.22)).frame(width: purge).offset(x: files + trash + held)
            }
            .clipShape(Capsule())
        }
    }
}

/// What the bar's colors mean, for the parts there are.
private struct SpaceLegend: View {
    let parts: SpaceBar.Parts

    var body: some View {
        let color = parts.nearlyFull ? Color.orange : Brand.color
        HStack(spacing: 10) {
            key(AnyShapeStyle(color), "Files", parts.files)
            if parts.trash > 0 { key(AnyShapeStyle(color.opacity(0.55)), "Trash", parts.trash) }
            if parts.held > 0 { key(AnyShapeStyle(Color.secondary.opacity(0.45)), "Held", parts.held) }
            if parts.purgeable > 0 { key(AnyShapeStyle(color.opacity(0.22)), "Purgeable", parts.purgeable) }
            key(AnyShapeStyle(.quaternary), "Free", parts.free)
        }
        .font(.system(size: 10).monospacedDigit())
        .foregroundStyle(.secondary)
    }

    private func key(_ style: AnyShapeStyle, _ title: String, _ bytes: Int64) -> some View {
        HStack(spacing: 3) {
            Circle().fill(style).frame(width: 6, height: 6)
            Text(title)
        }
        .help("\(title): \(Fmt.bytes(bytes))")
    }
}
