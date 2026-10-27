import AppKit
import SwiftUI

// MARK: - Tile

/// App Volume tile: up to three apps that are producing sound, each with mute (click the icon), a compact slider and
/// its level. Clicking a name opens the full list.
struct UtilAppVolumeView: View {
    let w: WidgetInstance
    @Environment(\.metrics) private var m
    private var service: UtilAppVolumeService { .shared }

    var body: some View {
        if UtilAppVolumePanel.sceneVariant {
            UtilAppVolumePanel.scenePreview()
        } else {
            tile
        }
    }

    private var tile: some View {
        Tile(width: w.kind.spec.width, padding: EdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10)) {
            if !service.isSupported {
                TileMessage(symbol: "speaker.slash", text: L("Needs macOS 14.2 or later"), tint: .cdGray)
            } else if service.apps.isEmpty {
                Button { UtilAppVolumePanel.toggle(w) } label: {
                    TileMessage(symbol: "speaker.zzz.fill", text: L("No apps playing"), tint: .cdGray)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                let hint = service.permissionDenied || service.awaitingPermission
                VStack(spacing: m.u(4)) {
                    if hint { UtilAppVolumeTileHint() }
                    ForEach(Array(service.apps.prefix(hint ? 2 : 3))) { app in
                        UtilAppVolumeTileRow(app: app, w: w)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .demand(UtilAppVolumeService.shared)
    }
}

private struct UtilAppVolumeTileRow: View {
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p
    var app: UtilAudioApp
    var w: WidgetInstance
    private var service: UtilAppVolumeService { .shared }

    var body: some View {
        let level = service.level(app.id)
        let enabled = service.canControl(app.id)
        let shown = level.muted ? 0 : level.volume
        HStack(spacing: m.u(6)) {
            Button { service.toggleMute(app.id) } label: {
                UtilAppVolumeIcon(app: app, size: 15)
                    .opacity(level.muted ? 0.45 : 1)
                    .overlay(alignment: .bottomTrailing) {
                        if level.muted {
                            Image(systemName: "speaker.slash.fill")
                                .font(.system(size: m.u(5), weight: .bold))
                                .foregroundStyle(p.calOnAccent)
                                .frame(width: m.u(9), height: m.u(9))
                                .background(Circle().fill(p.accent(UtilTint.red)))
                                .padding(.trailing, m.u(-3))
                                .padding(.bottom, m.u(-2.5))
                        }
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .disabled(!enabled)
            .help(level.muted ? L("Unmute") : L("Mute"))
            Button { UtilAppVolumePanel.toggle(w) } label: {
                Text(verbatim: app.name).dock(8.5, .semibold, p.secondary)
                    .truncationMode(.tail)
                    .frame(width: m.u(44), alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(app.name)
            UtilVolumeSlider(value: shown, enabled: enabled, thickness: 9) { service.setVolume($0, for: app.id) }
            Group {
                if service.failed.contains(app.id) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: m.u(8.5), weight: .semibold))
                        .foregroundStyle(p.accent(.cdOrange))
                        .help(L("NiceDock couldn't change this app's volume."))
                } else {
                    Text(verbatim: Fmt.percent(shown)).dock(8, .semibold, p.secondary, mono: true)
                }
            }
            .frame(minWidth: m.u(21), alignment: .trailing)
        }
        .frame(height: m.u(14))
    }
}

/// Replaces the first row while System Audio Recording is denied.
private struct UtilAppVolumeTileHint: View {
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p

    var body: some View {
        Button { Open.url(UtilAudioCapturePermission.settingsURL) } label: {
            HStack(spacing: m.u(6)) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: m.u(9), weight: .semibold))
                    .foregroundStyle(p.accent(.cdOrange))
                    .frame(width: m.u(15))
                Text(L("Allow System Audio Recording")).dock(8.5, .semibold, p.secondary)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .frame(height: m.u(14))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("Turn on System Audio Recording for NiceDock in Privacy & Security to change app volumes."))
    }
}

// MARK: - App icon

/// The app's icon; in reference renders the flat bundle artwork (as other scene frames); a drawn stand-in for apps
/// without a bundle (command-line tools) or not installed.
struct UtilAppVolumeIcon: View {
    @Environment(\.metrics) private var m
    var app: UtilAudioApp
    var size: CGFloat

    var body: some View {
        let s = m.u(size)
        if let path = app.iconPath, ReferenceScene.isActive, let art = AppsScene.icon(path) {
            Image(nsImage: art.image).resizable().interpolation(.high)
                .frame(width: s * art.scale, height: s * art.scale)
                .frame(width: s, height: s)
        } else if let path = app.iconPath {
            AppIcon(path: path, size: size)
        } else {
            let mark = Self.mark(app.id)
            RoundedRectangle(cornerRadius: s * 0.2, style: .continuous)
                .fill(mark.tint.gradient)
                .overlay(Image(systemName: mark.symbol).font(.system(size: s * 0.42, weight: .semibold)).foregroundStyle(Color(white: 1)))
                .frame(width: s * 0.815, height: s * 0.815)
                .frame(width: s, height: s)
        }
    }

    static func mark(_ key: String) -> (symbol: String, tint: Color) {
        if key == "us.zoom.xos" { return ("video.fill", CalBrand.zoomBlue) }
        return key.hasPrefix("/") ? ("terminal.fill", Color(white: 0.32)) : ("waveform", Color(white: 0.42))
    }
}

// MARK: - Rows (Audio panel section and App Volume panel)

/// "App Volume" list: every app producing sound with icon, name, level, slider and mute. Used in the Audio widget's
/// panel (`showsTitle`) and in the App Volume panel.
struct UtilAppVolumeSection: View {
    @Environment(\.palette) private var p
    var showsTitle: Bool
    private var service: UtilAppVolumeService { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showsTitle {
                Rectangle().fill(p.primary.opacity(0.08)).frame(height: 1).padding(.bottom, 2)
                HStack(spacing: 6) {
                    Text(L("App Volume")).font(.dock(10.5, .semibold)).foregroundStyle(p.secondary)
                    Spacer(minLength: 8)
                    if service.changedCount > 0 { resetButton }
                }
                .padding(.horizontal, 6)
            }
            if service.permissionDenied || service.awaitingPermission { UtilAppVolumePermissionHint() }
            if service.apps.isEmpty {
                Text(L("No apps are playing sound.")).font(.dock(11.5, .medium)).foregroundStyle(p.tertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
            } else {
                VStack(spacing: 2) {
                    ForEach(service.apps) { UtilAppVolumeRow(app: $0) }
                }
            }
            if !showsTitle && service.changedCount > 0 {
                HStack {
                    Spacer()
                    resetButton
                }
                .padding(.horizontal, 6)
            }
        }
        .demand(UtilAppVolumeService.shared)
    }

    private var resetButton: some View {
        Button { service.resetAll() } label: {
            Text(L("Reset All")).font(.dock(10.5, .semibold)).foregroundStyle(p.accent(.cdBlue))
        }
        .buttonStyle(.plain)
        .help(L("Set every app back to 100% and unmuted"))
    }
}

private struct UtilAppVolumeRow: View {
    @Environment(\.palette) private var p
    var app: UtilAudioApp
    private var service: UtilAppVolumeService { .shared }

    var body: some View {
        let level = service.level(app.id)
        let enabled = service.canControl(app.id)
        let shown = level.muted ? 0 : level.volume
        HStack(spacing: 10) {
            UtilAppVolumeIcon(app: app, size: 26)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(verbatim: app.name).font(.dock(12.5, .medium)).foregroundStyle(p.primary).lineLimit(1)
                    Spacer(minLength: 6)
                    if service.failed.contains(app.id) {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10, weight: .semibold)).foregroundStyle(p.accent(.cdOrange))
                            .help(L("NiceDock couldn't change this app's volume."))
                    } else {
                        Text(verbatim: Fmt.percent(shown)).font(.dock(10.5, .semibold, mono: true)).foregroundStyle(p.secondary)
                    }
                }
                UtilVolumeSlider(value: shown, enabled: enabled) { service.setVolume($0, for: app.id) }
            }
            Button { service.toggleMute(app.id) } label: {
                Image(systemName: level.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(level.muted ? p.accent(UtilTint.red) : p.secondary)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(level.muted ? p.accentSoft(UtilTint.red) : p.control))
                    .contentShape(Circle())
            }
            .buttonStyle(PressableStyle())
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.4)
            .help(level.muted ? L("Unmute") : L("Mute"))
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
    }
}

private struct UtilAppVolumePermissionHint: View {
    @Environment(\.palette) private var p

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "hand.raised.fill").font(.system(size: 15, weight: .semibold)).foregroundStyle(p.accent(.cdOrange))
            VStack(alignment: .leading, spacing: 7) {
                Text(L("Turn on System Audio Recording for NiceDock in Privacy & Security to change app volumes."))
                    .font(.dock(11, .medium)).foregroundStyle(p.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button { Open.url(UtilAudioCapturePermission.settingsURL) } label: {
                    Text(L("Open Privacy Settings")).font(.dock(11.5, .semibold)).foregroundStyle(p.calOnAccent)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(Capsule().fill(p.accent(.cdOrange)))
                }
                .buttonStyle(PressableStyle())
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(p.accent(.cdOrange).opacity(0.12)))
    }
}

// MARK: - Panel

@MainActor
enum UtilAppVolumePanel {
    static func toggle(_ w: WidgetInstance) {
        Panels.shared.toggle(w.id) { UtilAppVolumePanelView() }
    }

    /// `--scene reference` frames `appVolume-panel…` draw the panel instead of the tile.
    nonisolated static var sceneVariant: Bool { ReferenceScene.isActive && ReferenceScene.variant?.hasPrefix("panel") == true }

    static func scenePreview() -> some View {
        PanelChrome { UtilAppVolumePanelView() }
    }
}

struct UtilAppVolumePanelView: View {
    @Environment(\.palette) private var p
    private var service: UtilAppVolumeService { .shared }

    var body: some View {
        let n = service.apps.count
        VStack(alignment: .leading, spacing: 10) {
            PanelHeader(title: L("App Volume"), subtitle: n == 0 ? nil : n == 1 ? L("1 app playing") : L("%@ apps playing", Fmt.int(n))) {
                Button { Open.url("x-apple.systempreferences:com.apple.Sound-Settings.extension") } label: {
                    Image(systemName: "gearshape").font(.system(size: 13, weight: .semibold)).foregroundStyle(p.secondary)
                }
                .buttonStyle(.plain)
                .help(L("Sound Settings…"))
            }
            UtilAppVolumeSection(showsTitle: false)
        }
        .frame(width: 280)
    }
}

// MARK: - Settings

/// Settings → Widgets → App Volume.
struct UtilAppVolumeSettingsGroup: View {
    private var service: UtilAppVolumeService { .shared }

    var body: some View {
        let n = service.changedCount
        SettingsGroup(title: L("App Volume"), footer: L("An app plays through NiceDock only while its volume is below 100% or muted. macOS asks once for System Audio Recording.")) {
            ToggleRow(title: L("Remember volume per app"), subtitle: L("Restores an app's volume and mute the next time it plays."),
                      isOn: Binding(get: { service.remember }, set: { service.setRemember($0) }))
            SettingsRow(title: L("Reset all app volumes"),
                        subtitle: n == 0 ? L("Every app plays at full volume.") : n == 1 ? L("1 app changed") : L("%@ apps changed", Fmt.int(n))) {
                Button(L("Reset All")) { service.resetAll() }.disabled(n == 0)
            }
        }
    }
}
