import AppKit
import SwiftUI

struct StartView: View {
    @Bindable var model: WindowModel

    private let columns = [GridItem(.adaptive(minimum: 196, maximum: 250), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                VStack(spacing: 10) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 88, height: 88)
                        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
                    Text("Where did the space go?")
                        .font(.system(size: 22, weight: .semibold))
                    Text("Pick a place to scan. Silt reads it in parallel, shows results as they arrive, and stays live as files change.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 440)
                }
                .padding(.top, 36)

                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(model.locations) { loc in
                        LocationCard(location: loc, select: { model.select(loc.url.path) }, scan: { model.scan(loc.url) })
                    }
                    ChooseCard { model.chooseFolder() }
                }
                .frame(maxWidth: 900)

                if !model.hasFullDiskAccess {
                    FullDiskAccessCard(compact: false) { model.refreshLocations() }
                        .frame(maxWidth: 900)
                }

                Text("Tip: drop any folder onto this window or the Dock icon to scan it.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 24)
            }
            .padding(.horizontal, 32)
            .frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.top)
        .onAppear { model.refreshLocations() }
    }
}

/// A place that's picked but not scanned yet: what it is, and the button
/// that scans it.
struct ScanPrompt: View {
    let model: WindowModel
    let path: String

    var body: some View {
        let location = model.locations.first { $0.url.path == path }
        let name = location?.name ?? FileManager.default.displayName(atPath: path)
        VStack(spacing: 20) {
            Image(systemName: location?.symbol ?? "folder")
                .font(.system(size: 28))
                .foregroundStyle(Brand.color)
                .frame(width: 60, height: 60)
                .background(Brand.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(spacing: 4) {
                Text(name)
                    .font(.system(size: 22, weight: .semibold))
                Text(location.map { $0.isVolume ? "Volume" : "Your home folder" }
                     ?? path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            if let location, let f = location.usedFraction, let total = location.total, let avail = location.available {
                VStack(spacing: 5) {
                    CapacityBar(fraction: f).frame(height: 6)
                    HStack {
                        Text("\(Fmt.bytes(total - avail)) used")
                        Spacer()
                        Text("\(Fmt.bytes(avail)) available")
                    }
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                }
                .frame(width: 280)
            }
            VStack(spacing: 8) {
                BrandButton {
                    model.scan(URL(fileURLWithPath: path))
                } label: {
                    Text("Scan \(name)").padding(.horizontal, 10)
                }
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                if let last = lastScanned {
                    Text("Last scanned \(Fmt.age(UInt32(last.timeIntervalSince1970)))")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// When the scan saved for this place was last brought up to date.
    private var lastScanned: Date? {
        Snapshots.savedAt(for: URL(fileURLWithPath: path).resolvingSymlinksInPath().path)
    }
}

/// A place on the start screen: clicking it shows it, Scan scans it.
private struct LocationCard: View {
    let location: Location
    let select: () -> Void
    let scan: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: location.symbol)
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(Brand.color)
                    .frame(width: 30, height: 30)
                    .background(Brand.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(location.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if let f = location.usedFraction {
                CapacityBar(fraction: f).frame(height: 6)
            } else {
                // Keeps every card the same height.
                Color.clear.frame(height: 6)
            }
            HStack(alignment: .bottom) {
                if let total = location.total, let avail = location.available {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(Fmt.bytes(total - avail)) used")
                        Text("\(Fmt.bytes(avail)) available")
                    }
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("Scan", action: scan)
                    .controlSize(.small)
                    .help("Scan \(location.name)")
            }
            .frame(height: 28, alignment: .bottom)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(hovering ? Brand.color.opacity(0.6) : Color.primary.opacity(0.08))
        )
        .contentShape(RoundedRectangle(cornerRadius: 12))
        // The card itself only shows the place; its Scan button keeps its
        // own clicks.
        .onTapGesture(perform: select)
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Show", select)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }

    private var subtitle: String {
        let kind = location.isVolume ? "Volume" : "Your home folder"
        guard let saved = Snapshots.savedAt(for: location.url.path) else { return kind }
        return "\(kind) · scanned \(Fmt.age(UInt32(saved.timeIntervalSince1970)))"
    }
}

private struct ChooseCard: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
                Text("Choose a Folder…")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 112) // a location card's height
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    .foregroundStyle(hovering ? Brand.color.opacity(0.7) : Color.primary.opacity(0.2))
            )
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct FullDiskAccessCard: View {
    let compact: Bool
    let recheck: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 10) {
            HStack(spacing: 8) {
                Image(systemName: "lock.shield")
                    .font(.system(size: compact ? 13 : 17))
                    .foregroundStyle(.orange)
                Text("Some folders are hidden")
                    .font(.system(size: compact ? 12 : 13, weight: .semibold))
            }
            Text(compact
                 ? "Grant Full Disk Access so Silt can include Mail, Messages, and app containers."
                 : "macOS hides Mail, Messages and other apps’ data until you grant Full Disk Access, and asks separately before Silt reads Desktop, Documents and Downloads. Add Silt in System Settings, then reopen it.")
                .font(.system(size: compact ? 11 : 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Open System Settings") { FullDiskAccess.openSettings() }
                    .controlSize(compact ? .small : .regular)
                if !compact {
                    Button("Check Again", action: recheck)
                }
            }
        }
        .padding(compact ? 10 : 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.orange.opacity(0.25)))
    }
}
