import SwiftUI

/// The status bar's speed control: the mode, and why Automatic is easing
/// off when it is.
struct SpeedMenu: View {
    var compact = false
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let speed = SpeedController.shared
        Menu {
            Picker("Scan Speed", selection: Binding(get: { speed.mode }, set: { speed.mode = $0 })) {
                ForEach(ScanSpeed.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
            }
            .pickerStyle(.inline)
            Divider()
            Button("Speed Settings…") { openSettings() }
        } label: {
            Label(title(speed), systemImage: speed.mode.symbol)
                .labelStyle(compact ? AnyLabelStyle(.iconOnly) : AnyLabelStyle(.titleAndIcon))
        }
        // Plain, so it reads like the rest of the status bar.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(help(speed))
    }

    private func title(_ speed: SpeedController) -> String {
        speed.mode.title + (speed.pace.reason.map { " · \($0)" } ?? "")
    }

    private func help(_ speed: SpeedController) -> String {
        var text = "Scan speed: \(speed.mode.title). \(speed.mode.detail)"
        if let reason = speed.pace.reason { text += " Easing off now: \(reason)." }
        return text
    }
}

/// Wraps label styles so one modifier can pick between them.
private struct AnyLabelStyle: LabelStyle {
    private let make: (Configuration) -> AnyView
    init(_ style: some LabelStyle) { make = { AnyView(style.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

/// "Every 30 s".
private func everyText(_ seconds: TimeInterval) -> String {
    seconds < 60 ? "every \(Int(seconds.rounded())) s" : "every \(Int((seconds / 60).rounded())) min"
}

/// The folders Silt is updating less often, with a way to change that.
struct BusyFoldersPopover: View {
    let folders: [Session.BusyFolder]
    /// After a choice: the folder leaves the list, so the popover closes.
    var done: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Busy folders")
                .font(.system(size: 13, weight: .semibold))
            Text("These change constantly, so Silt updates them less often to save energy. A folder you have open still updates every couple of seconds.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            ForEach(folders) { f in
                HStack(spacing: 8) {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(Brand.color)
                    VStack(alignment: .leading, spacing: 1) {
                        Text((f.path as NSString).lastPathComponent)
                            .font(.system(size: 12))
                            .lineLimit(1)
                        Text(tilde((f.path as NSString).deletingLastPathComponent))
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    Spacer(minLength: 8)
                    Text(everyText(f.every))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                    Menu {
                        Button("Keep It Live") { choose(.live, f.path) }
                        Button("Update Slowly") { choose(.slow, f.path) }
                        Button("Pause Updates") { choose(.paused, f.path) }
                        Divider()
                        Button("Don’t Scan It") { choose(.excluded, f.path) }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Change how this folder is updated")
                }
            }
        }
        .padding(14)
        .frame(width: 380)
    }

    private func choose(_ rule: FolderRule, _ path: String) {
        done()
        FolderRules.shared.set(rule, for: path)
    }
}

func tilde(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
}

// MARK: Settings

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            SpeedSettings()
                .tabItem { Label("Speed", systemImage: "gauge.with.dots.needle.50percent") }
            FolderRulesSettings()
                .tabItem { Label("Folders", systemImage: "folder") }
        }
        .frame(width: 520)
    }
}

private struct GeneralSettings: View {
    @AppStorage(MenuBarMode.key) private var menuBar = true

    var body: some View {
        Form {
            Toggle(isOn: $menuBar) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keep Silt in the menu bar when its window is closed")
                    Text("Your scans stay ready: they’re put away to save memory, and catch up on what changed when you open Silt again.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .onChange(of: menuBar) { _, on in
                // Off with no window left: back in the Dock, so Silt can't end up out of sight.
                if !on, NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
            }
        }
        .padding(20)
    }
}

private struct SpeedSettings: View {
    var body: some View {
        let speed = SpeedController.shared
        Form {
            Picker("Scan speed:", selection: Binding(get: { speed.mode }, set: { speed.mode = $0 })) {
                ForEach(ScanSpeed.allCases) { mode in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(mode.title)
                        Text(mode.detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.bottom, 6)
                    .tag(mode)
                }
            }
            .pickerStyle(.radioGroup)
            if speed.mode == .automatic {
                LabeledContent("Right now:") {
                    Text(speed.pace.reason.map { "Easing off: \($0)." } ?? "Full speed for scans you start; upkeep in the background.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(20)
    }
}

struct FolderRulesSettings: View {
    var body: some View {
        let rules = FolderRules.shared
        VStack(alignment: .leading, spacing: 10) {
            Text("Folders you’ve told Silt to treat differently. A rule covers everything inside the folder.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if rules.rules.isEmpty {
                Text("No rules yet. Right-click a folder in Silt’s file list and choose Updates.")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                    ForEach(rules.rules.keys.sorted(), id: \.self) { path in
                        HStack(spacing: 8) {
                            Image(systemName: rules.rules[path]?.symbol ?? "folder")
                                .foregroundStyle(.secondary)
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                Text((path as NSString).lastPathComponent)
                                Text(tilde((path as NSString).deletingLastPathComponent))
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                            }
                            Spacer(minLength: 8)
                            Picker("", selection: Binding(get: { rules.rules[path] ?? .live },
                                                          set: { rules.set($0, for: path) })) {
                                ForEach(FolderRule.allCases) { Text($0.title).tag($0) }
                            }
                            .labelsHidden()
                            .fixedSize()
                            Button {
                                rules.set(nil, for: path)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("Remove this rule")
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        Divider().padding(.leading, 34)
                    }
                    }
                }
                .frame(minHeight: 160, maxHeight: 320)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .padding(20)
    }
}
