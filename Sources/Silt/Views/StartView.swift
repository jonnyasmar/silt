import AppKit
import SwiftUI

struct StartView: View {
    @Bindable var model: WindowModel

    private let columns = [GridItem(.adaptive(minimum: 220, maximum: 280), spacing: 14)]

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                VStack(spacing: 10) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 88, height: 88)
                        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
                    Text("Where did the space go?")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                    Text("Pick a place to scan. Silt reads it in parallel, shows results as they arrive, and stays live as files change.")
                        .font(.system(size: 13.5))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 440)
                }
                .padding(.top, 36)

                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(model.locations) { loc in
                        LocationCard(location: loc) { model.scan(loc.url) }
                    }
                    ChooseCard { model.chooseFolder() }
                }
                .frame(maxWidth: 900)

                if !model.hasFullDiskAccess {
                    FullDiskAccessCard(compact: false) { model.refreshLocations() }
                        .frame(maxWidth: 560)
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

private struct LocationCard: View {
    let location: Location
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: location.symbol)
                        .font(.system(size: 20, weight: .regular))
                        .foregroundStyle(Brand.color)
                        .frame(width: 30, height: 30)
                        .background(Brand.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(location.name)
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)
                        Text(location.isVolume ? "Volume" : location.url.path.replacingOccurrences(
                            of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .opacity(hovering ? 1 : 0)
                }
                if let f = location.usedFraction, let total = location.total, let avail = location.available {
                    VStack(alignment: .leading, spacing: 5) {
                        CapacityBar(fraction: f).frame(height: 6)
                        HStack {
                            Text("\(Fmt.bytes(total - avail)) used")
                            Spacer()
                            Text("\(Fmt.bytes(avail)) available")
                        }
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Your home folder")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(height: 22, alignment: .bottom)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(hovering ? Brand.color.opacity(0.6) : Color.primary.opacity(0.08))
            )
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
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
            .frame(maxWidth: .infinity, minHeight: 96)
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
                Text("See everything")
                    .font(.system(size: compact ? 12 : 14, weight: .semibold))
            }
            Text(compact
                 ? "Grant Full Disk Access so Silt can include Mail, Messages, and app containers."
                 : "macOS hides some folders (Mail, Messages, other apps’ containers) until you grant Full Disk Access. Without it, those folders show as locked. Add Silt in System Settings, then reopen it.")
                .font(.system(size: compact ? 11 : 12.5))
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
