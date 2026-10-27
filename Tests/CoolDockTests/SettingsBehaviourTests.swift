import AppKit
import AVFoundation
import Carbon.HIToolbox
import Contacts
import CoreLocation
import EventKit
import Photos
import SwiftUI
import Testing
@testable import CoolDock

/// Every Settings control writes `AppStore.shared.settings` through `setting(\.keyPath)` (or a store method); these
/// suites drive the same bindings and methods and check what changes in the app. Shared state is isolated as in
/// `Behaviour`; the macOS Dock, login items, global hot keys and the user's Library are never touched.

/// Counts `.coolDockSettingsChanged` / `.coolDockLanguageChanged` posts (what the Dock, menu bar and hot keys follow).
@MainActor
final class SettingsNotes {
    private(set) var settings = 0
    private(set) var language = 0
    private var tokens: [NSObjectProtocol] = []

    init() {
        let nc = NotificationCenter.default
        tokens.append(nc.addObserver(forName: .coolDockSettingsChanged, object: nil, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.settings += 1 }
        })
        tokens.append(nc.addObserver(forName: .coolDockLanguageChanged, object: nil, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.language += 1 }
        })
    }

    func stop() { tokens.forEach(NotificationCenter.default.removeObserver) }
}

extension Behaviour {
    /// Runs `body` and puts the shared settings back afterwards.
    static func restoringSettings(_ body: (AppStore) throws -> Void) rethrows {
        let saved = store.settings
        defer { store.settings = saved }
        try body(store)
    }

    /// A separate store on its own state file (Reset, profiles, persistence) so the shared one keeps its profiles.
    static func scratchStore(_ folder: URL) -> AppStore {
        prepare()
        return AppStore(stateFile: folder.appendingPathComponent("state.json"))
    }

    /// Saving is off for the whole test process; this turns it on for one synchronous step.
    static func withPersistence(_ body: () throws -> Void) rethrows {
        AppStore.persistenceEnabled = true
        defer { AppStore.persistenceEnabled = false }
        try body()
    }
}

// MARK: - Isolation

@MainActor
@Suite(.sharedState)
struct SettingsIsolationTests {
    @Test func testRunsNeverUseTheUsersLibrary() {
        let store = Behaviour.store
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let tmp = FileManager.default.temporaryDirectory.path
        #expect(AppPaths.testRoot != nil)
        #expect(AppPaths.stateFile.path.hasPrefix(tmp) && !AppPaths.stateFile.path.hasPrefix(home + "/Library"))
        #expect(AppPaths.cacheDirectory.path.hasPrefix(tmp) && DiskCache.dir.path.hasPrefix(tmp))
        #expect(!AppStore.persistenceEnabled)
        #expect(store.dockState.profiles.count >= 1)
    }
}

// MARK: - General

@MainActor
@Suite(.serialized, .sharedState)
struct GeneralPaneBehaviourTests {
    @Test func everySwitchBindingWritesThroughAndNotifies() {
        let notes = SettingsNotes()
        defer { notes.stop() }
        let switches: [WritableKeyPath<CoolDock.Settings, Bool>] = [
            \.showMenuBarIcon, \.monochrome, \.tileBackgrounds, \.reduceTransparency, \.shadow, \.animations,
            \.hideOnWindowHover, \.hideDuringFullscreen, \.runningAppsCollapsed, \.openFoldersInFinder, \.dragAppsToRearrange,
            \.showProfileSwitcher, \.dragToSwitchProfiles, \.showAppLabelsOnHover, \.showRunningIndicators,
            \.profileHotKeysEnabled, \.pauseWhenHidden, \.useEstedad, \.toggleHotKey.enabled,
            \.reservesDockSpace, \.reservesAfterDragging, \.assistantEnabled, \.assistantAllowsChanges, \.remembersAppVolumes
        ]
        Behaviour.restoringSettings { store in
            for kp in switches {
                let binding = setting(kp)
                let before = notes.settings
                let old = binding.wrappedValue
                binding.wrappedValue = !old
                #expect(store.settings[keyPath: kp] == !old, "\(kp)")
                #expect(notes.settings == before + 1, "\(kp) notifies once")
                binding.wrappedValue = old
            }
            // Optional-backed switches store an explicit value once flipped.
            setting(\.reservesDockSpace).wrappedValue = true
            setting(\.assistantEnabled).wrappedValue = true
            #expect(store.settings.reserveDockSpace == true && store.settings.aiAssistantEnabled == true)
            let before = notes.settings
            setting(\.showMenuBarIcon).wrappedValue = store.settings.showMenuBarIcon
            #expect(notes.settings == before, "writing the same value is not a change")
        }
    }

    @Test func temperatureUnitConvertsWeatherValues() {
        Behaviour.restoringSettings { store in
            setting(\.temperatureUnit).wrappedValue = .celsius
            #expect(Fmt.temp(21.4) == "21°" && Fmt.temp(-3.6) == "-4°")
            #expect(Fmt.speed(16.09) == "16 km/h")
            #expect(WeatherFmt.precip(25.4) == "25 mm" && WeatherFmt.precip(2.5) == "2.5 mm")

            setting(\.temperatureUnit).wrappedValue = .fahrenheit
            #expect(Fmt.temp(21.4) == "71°" && Fmt.temp(-40) == "-40°")
            #expect(Fmt.speed(16.09) == "10 mph")
            #expect(WeatherFmt.precip(25.4) == "1.00 in")

            setting(\.temperatureUnit).wrappedValue = .automatic
            let expected: TemperatureUnit = Locale.current.measurementSystem == .us ? .fahrenheit : .celsius
            #expect(store.settings.temperatureUnit.resolved == expected)
            #expect(Fmt.temp(0) == (expected == .fahrenheit ? "32°" : "0°"))
        }
    }

    @Test func screenshotFolderOverridesTheSystemLocation() {
        Behaviour.restoringSettings { store in
            store.settings.screenshotFolder = "~/Pictures/Shots"
            #expect(UtilScreenshotService.folder.path == FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/Shots").path)
            store.settings.screenshotFolder = nil // "Use Automatic Locations"
            #expect(!UtilScreenshotService.folder.path.hasSuffix("Pictures/Shots"))
        }
    }

    @Test func resetRestoresDefaultSettingsAndProfiles() {
        let folder = Behaviour.tempDirectory("reset")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = Behaviour.scratchStore(folder)
        store.settings.dockStyle = .white
        store.settings.dockScale = 1.3
        store.newProfile(named: "Gaming")
        store.addWidget(.calculator)
        store.resetEverything()
        #expect(store.settings == CoolDock.Settings())
        #expect(store.profiles.map(\.name) == ["Home", "Work", "System"])
        #expect(store.activeProfileID == store.profiles[0].id)
    }
}

// MARK: - Appearance

@MainActor
@Suite(.serialized, .sharedState)
struct AppearancePaneBehaviourTests {
    @Test func appThemeSetsTheAppAppearance() {
        Behaviour.restoringSettings { _ in
            setting(\.appTheme).wrappedValue = .dark
            #expect(NSApp.appearance?.name == .darkAqua)
            setting(\.appTheme).wrappedValue = .light
            #expect(NSApp.appearance?.name == .aqua)
            setting(\.appTheme).wrappedValue = .auto
            #expect(NSApp.appearance == nil)
        }
    }

    @Test func dockStyleAndSurfaceChangeThePalette() {
        Behaviour.restoringSettings { store in
            setting(\.dockStyle).wrappedValue = .darkGlass
            var p = store.palette
            #expect(!p.isLight && p.plate == Color.black.opacity(0.9) && p.primary == Color.white.opacity(0.86))

            setting(\.dockStyle).wrappedValue = .white
            p = store.palette
            #expect(p.isLight && p.plate == Color(white: 0.97) && p.primary == Color(white: 0.06))

            setting(\.dockStyle).wrappedValue = .black
            #expect(store.palette.plate == .black && store.palette.tileFill == Color.white.opacity(0.06))

            setting(\.dockStyle).wrappedValue = .transparent
            setting(\.widgetSurface).wrappedValue = .white
            p = store.palette
            #expect(p.plate == .clear && p.isLight && p.tileFill == Color(white: 0.97))
            setting(\.widgetSurface).wrappedValue = .darkGlass
            #expect(store.palette.tileFill == Color.black.opacity(0.85) && !store.palette.isLight)
        }
    }

    @Test func colorsTilesAndTransparency() {
        Behaviour.restoringSettings { store in
            store.settings.dockStyle = .darkGlass
            setting(\.monochrome).wrappedValue = true
            #expect(store.palette.accent(.cdRed) == store.palette.primary, "Monochrome drops accent colours")
            setting(\.monochrome).wrappedValue = false
            #expect(store.palette.accent(.cdRed) == .cdRed)

            setting(\.tileBackgrounds).wrappedValue = false
            #expect(!store.palette.drawTiles)
            store.settings.dockStyle = .transparent
            #expect(store.palette.drawTiles, "transparent docks always draw tiles")
            store.settings.dockStyle = .darkGlass

            setting(\.reduceTransparency).wrappedValue = true
            #expect(store.reduceTransparency && store.palette.plate == Color(red: 11 / 255, green: 11 / 255, blue: 11 / 255))
            setting(\.reduceTransparency).wrappedValue = false
            store.systemReduceTransparency = true // macOS Reduce Transparency has the same effect
            #expect(store.reduceTransparency)
            store.systemReduceTransparency = false
            #expect(!store.reduceTransparency && store.palette.plate == Color.black.opacity(0.9))
        }
    }

    @Test func sizeSpacingAndCornerSlidersDriveTheMetrics() {
        Behaviour.restoringSettings { store in
            setting(\.dockScale).wrappedValue = 1.2
            setting(\.widgetSpacing).wrappedValue = 10
            setting(\.cornerRadius).wrappedValue = 16
            let m = store.metrics
            #expect(abs(m.tileHeight - 62 * 1.2) < 1e-9 && abs(m.gap - 12) < 1e-9)
            #expect(abs(m.tileRadius - 19.2) < 1e-9 && abs(m.plateRadius - 28.8) < 1e-9 && abs(m.padding - 9.6) < 1e-9)
            #expect(abs(m.u(100) - 120) < 1e-9)
        }
    }

    @Test func animationsSwitchControlsProfileAnimations() {
        Behaviour.restoringSettings { store in
            setting(\.animations).wrappedValue = true
            #expect(store.switchAnimation == .spring(response: 0.35, dampingFraction: 0.86))
            setting(\.animations).wrappedValue = false
            #expect(store.switchAnimation == nil)
        }
    }
}

// MARK: - Layout

@MainActor
@Suite(.serialized, .sharedState)
struct LayoutPaneBehaviourTests {
    // A 1440×900 display: menu bar 25 pt, macOS Dock 70 pt.
    let full = NSRect(x: 0, y: 0, width: 1440, height: 900)
    let visible = NSRect(x: 0, y: 70, width: 1440, height: 805)
    let size = CGSize(width: 600, height: 100)

    func frame(_ edit: (inout CoolDock.Settings) -> Void, revealed: Bool = true) -> NSRect {
        var s = CoolDock.Settings()
        edit(&s)
        return DockWindow.frame(s, screenID: "D1", size: size, visible: visible, full: full, revealed: revealed)
    }

    @Test func fixedPositionsAndEdgeDistance() {
        #expect(frame { $0.scenario = .fixed } == NSRect(x: 420, y: 78, width: 600, height: 100))
        #expect(frame { $0.scenario = .fixed; $0.fixedPosition = .topRight } == NSRect(x: 832, y: 767, width: 600, height: 100))
        #expect(frame { $0.scenario = .fixed; $0.fixedPosition = .bottomLeft; $0.edgeDistance = 20 } == NSRect(x: 20, y: 90, width: 600, height: 100))
        #expect(frame { $0.scenario = .fixed; $0.fixedPosition = .topCenter; $0.edgeDistance = 0 }.maxY == visible.maxY)
    }

    @Test func revealScenariosHideOffTheEdge() {
        #expect(frame { $0.scenario = .revealBottom }.minY == 78)
        #expect(frame({ $0.scenario = .revealBottom }, revealed: false).maxY == -4, "parked below the screen")
        #expect(frame { $0.scenario = .swapBottom }.minY == 8, "measured from the screen edge, over the macOS Dock")
        #expect(frame { $0.scenario = .replaceAutoHide; $0.alignment = .right }.maxX == 1432)
        #expect(frame { $0.scenario = .revealTop; $0.alignment = .left }.origin == CGPoint(x: 8, y: 767))
        #expect(frame({ $0.scenario = .revealTop }, revealed: false).minY == 879, "parked above the menu bar")
    }

    @Test func floatingOriginIsKeptOnScreenAndRecenterResetsIt() {
        #expect(frame { $0.scenario = .floating; $0.floatingOrigins = ["D1": CGPointCodable(x: 100, y: 200)] }.origin == CGPoint(x: 100, y: 200))
        #expect(frame { $0.scenario = .floating; $0.floatingOrigins = ["D1": CGPointCodable(x: 5000, y: -300)] }.origin == CGPoint(x: 840, y: 0))
        #expect(frame { $0.scenario = .floating; $0.floatingOrigins = ["D2": CGPointCodable(x: 100, y: 200)] }.origin == CGPoint(x: 420, y: 78),
                "another display's origin doesn't apply")
        Behaviour.restoringSettings { store in
            store.settings.floatingOrigins = ["D1": CGPointCodable(x: 1, y: 2)]
            store.settings.floatingOrigins = [:] // Recenter
            #expect(store.settings.floatingOrigins.isEmpty)
        }
    }

    @Test func replaceScenariosAskToHideTheMacOSDockWithoutTouchingItHere() {
        #expect(LayoutScenario.allCases.filter { SystemDock.intent(for: $0) == .hide } == [.replaceDock, .replaceAutoHide])
        // Picking a scenario in Settings only changes settings; the Dock controller (not running in tests) applies it.
        let autohide = SystemDock.shared.autohides
        Behaviour.restoringSettings { store in
            for scenario in LayoutScenario.allCases { setting(\.scenario).wrappedValue = scenario }
            #expect(store.settings.scenario == .floating)
        }
        #expect(SystemDock.shared.autohides == autohide, "com.apple.dock autohide unchanged")
        #expect(UserDefaults.standard.dictionary(forKey: "CoolDockDockBackup") == nil, "the Dock was never replaced")
    }

    @Test func revealTimingSlidersAreStored() {
        Behaviour.restoringSettings { store in
            setting(\.showDelay).wrappedValue = 0.35
            setting(\.hideDelay).wrappedValue = 1.5
            setting(\.triggerSize).wrappedValue = 30
            setting(\.alignment).wrappedValue = .left
            #expect(store.settings.showDelay == 0.35 && store.settings.hideDelay == 1.5 && store.settings.triggerSize == 30)
            #expect(store.settings.alignment == .left)
        }
    }
}

// MARK: - Screens

@MainActor
@Suite(.serialized, .sharedState)
struct ScreensPaneBehaviourTests {
    let laptop = KnownDisplay(id: "BUILTIN", name: "Built-in Retina Display", builtIn: true)
    let studio = KnownDisplay(id: "STUDIO", name: "Studio Display", builtIn: false)
    let tv = KnownDisplay(id: "TV", name: "LG TV", builtIn: false)

    func targets(_ edit: (inout CoolDock.Settings) -> Void, connected: [String] = ["BUILTIN", "STUDIO"], builtIn: String? = "BUILTIN",
                 main: String? = "STUDIO") -> [String] {
        var s = CoolDock.Settings()
        s.displays = [laptop, studio, tv]
        edit(&s)
        return DockController.targetIDs(s, connected: connected, builtIn: builtIn, main: main)
    }

    @Test func oneDisplayPrefersTheChosenOneThenBuiltIn() {
        #expect(targets { $0.screensMode = .one } == ["BUILTIN"])
        #expect(targets { $0.screensMode = .one; $0.preferredDisplay = "STUDIO" } == ["STUDIO"])
        #expect(targets { $0.screensMode = .one; $0.preferredDisplay = "TV" } == ["BUILTIN"], "disconnected: back to the built-in display")
        #expect(targets({ $0.preferredDisplay = "TV" }, connected: ["STUDIO", "TV2"], builtIn: nil, main: "TV2") == ["TV2"])
        #expect(targets({ $0.preferredDisplay = nil }, connected: ["X", "Y"], builtIn: nil, main: nil) == ["X"])
        #expect(targets({ _ in }, connected: []).isEmpty)
    }

    @Test func allAndAttachedDisplays() {
        #expect(targets { $0.screensMode = .all } == ["BUILTIN", "STUDIO"])
        #expect(targets { $0.screensMode = .attached } == ["BUILTIN"], "the first attached display in the list wins")
        #expect(targets { $0.screensMode = .attached; $0.displays[0].attached = false } == ["STUDIO"])
        #expect(targets { $0.screensMode = .attached; $0.moveDisplay("STUDIO", by: -1) } == ["STUDIO"], "Move Up changes the winner")
        #expect(targets { $0.screensMode = .attached; for i in $0.displays.indices { $0.displays[i].attached = false } }.isEmpty,
                "nothing attached: CoolDock stays hidden")
    }

    @Test func moveRenameAndForget() {
        var s = CoolDock.Settings()
        s.displays = [laptop, studio, tv]
        s.moveDisplay("TV", by: -1)
        #expect(s.displays.map(\.id) == ["BUILTIN", "TV", "STUDIO"])
        s.moveDisplay("BUILTIN", by: -1)
        s.moveDisplay("STUDIO", by: 5)
        #expect(s.displays.map(\.id) == ["BUILTIN", "TV", "STUDIO"], "moves stop at the ends")
        s.renameDisplay("STUDIO", to: "  Desk  ")
        #expect(s.displays[2].displayName == "Desk")
        s.renameDisplay("STUDIO", to: "")
        #expect(s.displays[2].displayName == "Studio Display", "an empty name shows the display's own")
        s.displays.removeAll { $0.id == "TV" } // Forget
        #expect(s.displays.map(\.id) == ["BUILTIN", "STUDIO"])
        Behaviour.restoringSettings { store in
            setting(\.screensMode).wrappedValue = .attached
            store.settings.preferredDisplay = "STUDIO"
            #expect(store.settings.screensMode == .attached && store.settings.preferredDisplay == "STUDIO")
        }
    }
}

// MARK: - Profiles & Widgets

@MainActor
@Suite(.serialized, .sharedState)
struct ProfilesAndWidgetsPaneBehaviourTests {
    let folder = Behaviour.tempDirectory("profiles")
    func cleanUp() { try? FileManager.default.removeItem(at: folder) }

    @Test func addRenameSwitchAndDeleteProfiles() {
        defer { cleanUp() }
        let store = Behaviour.scratchStore(folder)
        #expect(store.profiles.count == 3 && store.activeProfile.name == "Home")

        let gaming = store.newProfile()!
        #expect(store.activeProfileID == gaming.id && gaming.name == "Profile 4" && gaming.widgets.isEmpty)
        let i = store.activeIndex
        store.profiles[i].name = "Gaming"
        store.profiles[i].symbol = "gamecontroller"
        #expect(store.activeProfile.name == "Gaming" && store.activeProfile.symbol == "gamecontroller")

        // Each profile keeps its own widgets.
        store.addWidget(.calculator)
        store.switchProfile(to: 0)
        #expect(!store.activeProfile.widgets.contains { $0.kind == .calculator })
        store.switchProfile(by: -1) // wraps around to the last profile
        #expect(store.activeProfile.name == "Gaming" && store.activeProfile.widgets.map(\.kind) == [.calculator])

        while store.profiles.count < DockProfile.maxProfiles { store.newProfile() }
        #expect(store.newProfile() == nil, "at most eight profiles")

        store.switchProfile(to: 3)
        let gamingID = store.activeProfileID
        store.deleteProfile(gamingID)
        #expect(!store.profiles.contains { $0.id == gamingID } && store.activeProfileID == store.profiles[2].id,
                "deleting the active profile activates the one before it")
        while store.profiles.count > 1 { store.deleteProfile(store.profiles[0].id) }
        store.deleteProfile(store.profiles[0].id)
        #expect(store.profiles.count == 1, "the last profile can't be deleted")
    }

    @Test func duplicateCopiesWidgetsWithNewIdentitiesAndSecrets() throws {
        defer { cleanUp() }
        let store = Behaviour.scratchStore(folder)
        store.switchProfile(to: 1) // Work
        store.addWidget(.stripeRevenue)
        let source = store.activeProfile
        let paid = try #require(source.widgets.last)
        Secrets.set("sk_test_behaviour", paid.id, "token")
        defer { Secrets.removeAll(for: paid.id) }

        let copy = try #require(store.newProfile(duplicating: source))
        #expect(copy.name == "Work Copy" && copy.symbol == source.symbol)
        #expect(copy.widgets.map(\.kind) == source.widgets.map(\.kind) && copy.widgets.map(\.config) == source.widgets.map(\.config))
        #expect(Set(copy.widgets.map(\.id)).isDisjoint(with: source.widgets.map(\.id)))
        let copied = copy.widgets.last!
        #expect(Secrets.get(copied.id, "token") == "sk_test_behaviour")

        store.deleteProfile(copy.id)
        #expect(Secrets.get(copied.id, "token") == nil, "deleting a profile removes its widgets' credentials")
        #expect(Secrets.get(paid.id, "token") == "sk_test_behaviour")
    }

    @Test func widgetsAddReorderRemoveAndVisibility() {
        defer { cleanUp() }
        let store = Behaviour.scratchStore(folder)
        store.switchProfile(to: 2) // System
        let start = store.activeProfile.widgets.map(\.kind)

        store.addWidget(.space, config: ["width": "40"], at: 0)
        #expect(store.activeProfile.widgets.first?.kind == .space && store.activeProfile.widgets.first?.string("width") == "40")
        store.addWidget(.timer)
        let timer = store.activeProfile.widgets.last!
        #expect(timer.string("minutes") == "5", "catalog defaults fill the config")

        store.moveWidget(timer.id, to: 1) // ⌘-drag in the Dock
        #expect(store.activeProfile.widgets[1].id == timer.id)
        let count = store.activeProfile.widgets.count
        store.updateActive { $0.widgets.move(fromOffsets: IndexSet(integer: 0), toOffset: count) } // Settings list drag
        #expect(store.activeProfile.widgets.last?.kind == .space)

        Secrets.set("x", timer.id, "token")
        store.removeWidget(timer.id)
        #expect(!store.activeProfile.widgets.contains { $0.id == timer.id } && Secrets.get(timer.id, "token") == nil)
        #expect(store.activeProfile.widgets.map(\.kind) == start + [.space])

        // Visibility rules (right-click → Visibility, or the Widgets pane picker).
        let evaluator = VisibilityEvaluator.shared
        var w = WidgetInstance(kind: .app, config: ["path": "/System/Library/CoreServices/Finder.app"])
        #expect(evaluator.isVisible(w))
        w.visibility = .whileRunning
        #expect(evaluator.isVisible(w), "Finder is always running")
        w.config["path"] = "/Applications/CoolDock Behaviour Test.app"
        #expect(!evaluator.isVisible(w))
        store.updateWidget(store.activeProfile.widgets[0].id) { $0.visibility = .whileRunning }
        #expect(store.activeProfile.widgets[0].visibility == .whileRunning)
    }

    @Test func everyWidgetKindHasACatalogEntry() {
        for kind in WidgetKind.allCases {
            let spec = kind.spec
            #expect(spec.width > 0 && !spec.localizedTitle.isEmpty, "\(kind)")
            #expect(WidgetInstance(kind: kind).config == spec.defaults, "\(kind)")
        }
    }

    @Test func appVolumeRememberAndResetAllUseTheSettings() {
        Behaviour.restoringSettings { store in
            store.settings.appVolumes = nil
            store.settings.appVolumeRemember = nil
            let service = UtilAppVolumeService(storage: UtilAppVolumeSettingsStorage(), monitor: false, taps: false, observeSettings: true)
            service.saveDelay = 0
            #expect(service.remember, "remember is on by default")

            Behaviour.withPersistence {
                service.setVolume(0.3, for: "com.apple.Music")
                service.setMuted(true, for: "us.zoom.xos")
            }
            #expect(store.settings.appVolumes == ["com.apple.Music": UtilAppVolumeLevel(volume: 0.3, muted: false),
                                                  "us.zoom.xos": UtilAppVolumeLevel(volume: 1, muted: true)])
            #expect(service.changedCount == 2)

            Behaviour.withPersistence { service.resetAll() } // Reset All
            #expect(store.settings.appVolumes == nil && service.changedCount == 0 && service.level("com.apple.Music") == .unity)

            Behaviour.withPersistence { service.setRemember(false) } // "Remember volume per app" off
            #expect(store.settings.appVolumeRemember == false && !store.settings.remembersAppVolumes)
            Behaviour.withPersistence { service.setVolume(0.5, for: "com.apple.Safari") }
            #expect(store.settings.appVolumes == nil, "nothing is saved while remember is off")
            Behaviour.withPersistence { service.setRemember(true) }
            #expect(store.settings.appVolumes == ["com.apple.Safari": UtilAppVolumeLevel(volume: 0.5, muted: false)])

            // Changed elsewhere (Reset CoolDock, the assistant): the running service follows.
            store.settings.appVolumes = ["com.apple.Music": UtilAppVolumeLevel(volume: 0.2, muted: false)]
            #expect(service.level("com.apple.Music").volume == 0.2 && service.level("com.apple.Safari") == .unity)
        }
    }
}

// MARK: - Shortcuts

@MainActor
@Suite(.serialized, .sharedState)
struct ShortcutsPaneBehaviourTests {
    let ctrlOptCmd: UInt32 = UInt32(controlKey | optionKey | cmdKey)

    @Test func recordingAcceptsCombinationsAndRefusesBareKeys() {
        typealias R = ShortcutRecorder
        #expect(R.outcome(keyCode: UInt16(kVK_Escape), flags: [.command]) == .cancel)
        #expect(R.outcome(keyCode: UInt16(kVK_ANSI_D), flags: []) == .reject, "a key without modifiers would steal typing")
        #expect(R.outcome(keyCode: UInt16(kVK_ANSI_Comma), flags: [.command]) == .reject, "⌘, stays Settings")
        #expect(R.outcome(keyCode: UInt16(kVK_ANSI_D), flags: [.control, .option, .command])
                == .record(HotKeySpec(keyCode: UInt32(kVK_ANSI_D), modifiers: ctrlOptCmd, enabled: true)))
        #expect(R.outcome(keyCode: UInt16(kVK_F5), flags: [.shift, .capsLock])
                == .record(HotKeySpec(keyCode: UInt32(kVK_F5), modifiers: UInt32(shiftKey), enabled: true)))

        #expect(ModifierRecorder.mask(for: [.command]) == nil, "one modifier is not enough for the profile prefix")
        #expect(ModifierRecorder.mask(for: [.command, .option]) == UInt32(cmdKey | optionKey))
    }

    @Test func shortcutLabels() {
        #expect(HotKeys.modifierString(ctrlOptCmd) == "⌃⌥⌘")
        #expect(HotKeys.modifierString(UInt32(shiftKey | cmdKey)) == "⇧⌘")
        #expect(HotKeys.keyString(UInt32(kVK_F5)) == "F5" && HotKeys.keyString(UInt32(kVK_Space)) == "Space")
        #expect(HotKeys.display(HotKeySpec(keyCode: UInt32(kVK_LeftArrow), modifiers: UInt32(controlKey))) == "⌃←")
    }

    @Test func recordedShortcutsAreStoredAndResetRestoresTheDefaults() {
        Behaviour.restoringSettings { store in
            let custom = HotKeySpec(keyCode: UInt32(kVK_F5), modifiers: UInt32(shiftKey), enabled: true)
            setting(\.toggleHotKey).wrappedValue = custom
            setting(\.profileHotKeyModifiers).wrappedValue = UInt32(cmdKey | shiftKey)
            setting(\.toggleHotKey.enabled).wrappedValue = false
            #expect(store.settings.toggleHotKey == HotKeySpec(keyCode: UInt32(kVK_F5), modifiers: UInt32(shiftKey), enabled: false))

            store.settings.toggleHotKey = CoolDock.Settings().toggleHotKey // Reset
            store.settings.profileHotKeyModifiers = CoolDock.Settings().profileHotKeyModifiers // Reset
            #expect(store.settings.toggleHotKey == HotKeySpec(keyCode: UInt32(kVK_ANSI_D), modifiers: ctrlOptCmd, enabled: true))
            #expect(HotKeys.modifierString(store.settings.profileHotKeyModifiers) == "⌃⌥⌘")
        }
    }
}

// MARK: - Language & Region

/// Switches the app's language for a few synchronous steps at a time and always restores English.
@MainActor
@Suite(.serialized, .sharedState)
struct LanguagePaneBehaviourTests {
    init() { Behaviour.prepare() }

    @Test func persianSwitchesStringsDirectionDigitsCalendarAndTypeface() {
        let store = Behaviour.store
        let notes = SettingsNotes()
        defer { notes.stop() }
        let revision = store.languageRevision
        Behaviour.withLanguage(.fa) {
            #expect(Localizer.language == .fa && store.resolvedLanguage == .fa)
            #expect(notes.language == 1 && store.languageRevision == revision + 1)
            #expect(store.layoutDirection == .rightToLeft)
            #expect(L("Today") == "امروز" && L("Tomorrow") != "Tomorrow")
            #expect(Fmt.digits("2026") == "۲۰۲۶" && Fmt.int(1234) == "۱٬۲۳۴" && Fmt.percent(0.5) == "۵۰٪")
            #expect(Fmt.calendar.identifier == .persian, "automatic calendar for Persian is the Solar Hijri one")
            #expect(Font.dock(13) == Font.custom("Estedad-SemiBold", fixedSize: 13 * 0.94))
            #expect(Font.ui(13) == Font.custom("Estedad-Regular", fixedSize: 13 * 0.96))
        }
        #expect(Localizer.language == .en && store.layoutDirection == .leftToRight && notes.language == 2)
        #expect(Font.dock(13) == Font.system(size: 13, weight: .semibold, design: .rounded))
        #expect(L("Today") == "Today" && Fmt.digits("2026") == "2026")
    }

    @Test func estedadIsBundledAndCanBeTurnedOff() {
        DockFonts.registerBundledFonts()
        #expect(NSFont(name: "Estedad-SemiBold", size: 13) != nil && DockFonts.estedadNSFont(13, weight: .bold).fontName == "Estedad-Bold")
        Behaviour.withLanguage(.fa, estedad: false) {
            #expect(!AppStore.estedadEnabled)
            #expect(Font.dock(13) == Font.system(size: 13, weight: .semibold, design: .rounded))
        }
        #expect(AppStore.estedadEnabled)
    }

    @Test func arabicGermanAndRegionOptions() {
        let store = Behaviour.store
        Behaviour.withLanguage(.ar) {
            #expect(store.layoutDirection == .rightToLeft && Fmt.digits("2026") == "٢٠٢٦")
            #expect(Fmt.calendar.identifier == .gregorian)
            #expect(Font.dock(13) == Font.custom("Estedad-SemiBold", fixedSize: 13 * 0.94))
        }
        Behaviour.withLanguage(.de) {
            #expect(store.layoutDirection == .leftToRight && Fmt.number(1234.5, decimals: 1) == "1.234,5")
            #expect(L("Today") == "Heute")
        }
        Behaviour.withLanguage(.fa, digits: .latin) {
            #expect(Fmt.digits("2026") == "2026" && !Fmt.nativeDigits)
        }
        Behaviour.withLanguage(.en, digits: .native) {
            #expect(Fmt.digits("2026") == "2026", "native digits exist only for Persian and Arabic")
        }
        Behaviour.withLanguage(.fa, calendar: .gregorian) { #expect(Fmt.calendar.identifier == .gregorian) }
        Behaviour.withLanguage(.en, calendar: .islamic) { #expect(Fmt.calendar.identifier == .islamicUmmAlQura) }

        let date = TestDate.local(2026, 10, 27, 13, 5)
        Behaviour.withLanguage(.en, clock: .h12) {
            #expect(Fmt.clock(date) == "1:05" && Fmt.ampm(date) != nil)
        }
        Behaviour.withLanguage(.en, clock: .h24) {
            #expect(Fmt.clock(date) == "13:05" && Fmt.ampm(date) == nil)
        }
        #expect(Localizer.language == .en)
    }
}

// MARK: - Privacy & Permissions

@MainActor
@Suite(.serialized, .sharedState)
struct PrivacyPaneBehaviourTests {
    @Test func permissionRowsShowWhatTCCReports() {
        typealias P = PrivacyPane
        #expect(P.status(EKAuthorizationStatus.fullAccess) == .granted && P.status(EKAuthorizationStatus.writeOnly) == .denied)
        #expect(P.status(EKAuthorizationStatus.denied) == .denied && P.status(EKAuthorizationStatus.notDetermined) == .notDetermined)
        #expect(P.status(CNAuthorizationStatus.authorized) == .granted && P.status(CNAuthorizationStatus.restricted) == .denied)
        #expect(P.status(CLAuthorizationStatus.authorizedAlways) == .granted && P.status(CLAuthorizationStatus.denied) == .denied)
        #expect(P.status(PHAuthorizationStatus.limited) == .granted && P.status(PHAuthorizationStatus.notDetermined) == .notDetermined)
        #expect(P.status(AVAuthorizationStatus.authorized) == .granted && P.status(AVAuthorizationStatus.restricted) == .denied)
    }

    @Test func calendarFeedsAddUpdateAndRemove() throws {
        let svc = CalendarFeedService.shared
        try Behaviour.restoringSettings { store in
            store.settings.calendarFeeds = nil
            // Port 9 on this Mac refuses at once: the immediate download fails quietly, nothing leaves the machine.
            #expect(svc.add("https://localhost:9/cooldock-behaviour.ics") == nil)
            #expect(svc.add("webcal://localhost:9/cooldock-behaviour.ics") == "This feed is already added.")
            #expect(svc.add("mailto:someone@example.com") == "Enter a webcal:// or https:// link to an .ics calendar.")

            let open = try #require(store.settings.calendarFeeds?.first)
            #expect(open.url == "https://localhost:9/cooldock-behaviour.ics" && open.host == "localhost" && open.color == CalendarFeed.palette[0])
            #expect(svc.hasFeeds)

            #expect(svc.add("https://localhost:9/team.ics?token=s3cr3t-behaviour") == nil)
            let secret = try #require(store.settings.calendarFeeds?.last)
            #expect(secret.url == nil && secret.isPrivate, "secret links stay out of state.json")
            #expect(secret.link == "https://localhost:9/team.ics?token=s3cr3t-behaviour" && secret.color == CalendarFeed.palette[1])
            let saved = String(decoding: try JSONEncoder().encode(store.settings), as: UTF8.self)
            #expect(!saved.contains("s3cr3t"))

            svc.update(open.id) { $0.enabled = false; $0.name = "Holidays" }
            #expect(store.settings.calendarFeeds?.first?.enabled == false && store.settings.calendarFeeds?.first?.displayName == "Holidays")

            svc.remove(secret.id)
            #expect(Secrets.get(secret.id, CalendarFeed.secretKey) == nil, "removing a feed forgets its link")
            svc.remove(open.id)
            #expect(store.settings.calendarFeeds == [] && !svc.hasFeeds)
        }
    }

    @Test func assistantSwitches() {
        Behaviour.restoringSettings { store in
            #expect(!store.settings.assistantEnabled && !store.settings.assistantAllowsChanges, "off by default")
            setting(\.assistantEnabled).wrappedValue = true
            setting(\.assistantAllowsChanges).wrappedValue = true
            #expect(store.dockState.settings.assistantEnabled && store.dockState.settings.assistantAllowsChanges)
        }
    }
}

// MARK: - Performance & About

@MainActor
@Suite(.serialized, .sharedState)
struct PerformancePaneBehaviourTests {
    @Test func statsIntervalRetimesTheRunningSampler() async {
        let monitor = SystemMonitor.shared
        await Behaviour.restoringSettingsAsync { store in
            store.settings.systemSampleInterval = 2
            monitor.subscribe("behaviour-test")
            #expect(monitor.sampleInterval == 2)
            setting(\.systemSampleInterval).wrappedValue = 5
            await Behaviour.wait { monitor.sampleInterval == 5 }
            #expect(monitor.sampleInterval == 5, "the slider applies while widgets are showing")
            setting(\.systemSampleInterval).wrappedValue = 0.2
            await Behaviour.wait { monitor.sampleInterval == 1 }
            #expect(monitor.sampleInterval == 1, "never faster than once a second")
            monitor.unsubscribe("behaviour-test")
            #expect(monitor.sampleInterval == nil)
        }
    }

    @Test func pauseWhileHiddenUnmountsTheWidgets() {
        Behaviour.restoringSettings { _ in
            let model = DockWindowModel(screenID: "behaviour")
            model.lastStripSize = CGSize(width: 800, height: 78)
            model.revealed = false
            setting(\.pauseWhenHidden).wrappedValue = true
            #expect(model.widgetsPaused)
            model.revealed = true
            #expect(!model.widgetsPaused, "shown: widgets run")
            model.revealed = false
            setting(\.pauseWhenHidden).wrappedValue = false
            #expect(!model.widgetsPaused, "the switch off keeps widgets running while hidden")
        }
    }

    @Test func clearCacheEmptiesTheCacheFolder() throws {
        let file = DiskCache.url("behaviour-clear-test")
        try Data("{}".utf8).write(to: file)
        #expect(FileManager.default.fileExists(atPath: file.path))
        DiskCache.clear()
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(FileManager.default.fileExists(atPath: DiskCache.dir.path), "the folder itself stays")
    }

    @Test func aboutShowsTheVersion() {
        #expect(L("Version %@ (%@)", "1.2", "34") == "Version 1.2 (34)")
        Behaviour.withLanguage(.fa) {
            #expect(L("Version %@ (%@)", "1.2", "34").contains("1.2"))
        }
    }
}

extension Behaviour {
    static func restoringSettingsAsync(_ body: (AppStore) async throws -> Void) async rethrows {
        let saved = store.settings
        defer { store.settings = saved }
        try await body(store)
    }
}

// MARK: - Persistence

@MainActor
@Suite(.serialized, .sharedState)
struct SettingsPersistenceBehaviourTests {
    let folder = Behaviour.tempDirectory("persistence")
    func cleanUp() { try? FileManager.default.removeItem(at: folder) }

    @Test func everythingRoundTripsThroughTheStateFile() async throws {
        defer { cleanUp() }
        let file = folder.appendingPathComponent("state.json")
        let store = Behaviour.scratchStore(folder)
        var s = store.settings
        s.temperatureUnit = .fahrenheit
        s.dockStyle = .white
        s.dockScale = 1.25
        s.scenario = .revealTop
        s.screensMode = .attached
        s.displays = [KnownDisplay(id: "D", name: "Desk", customName: "Left", builtIn: false, attached: true, lastSeen: TestDate.local(2026, 1, 1))]
        s.toggleHotKey = HotKeySpec(keyCode: 96, modifiers: 512, enabled: false)
        s.systemSampleInterval = 4
        s.pauseWhenHidden = false
        s.calendarFeeds = [CalendarFeed(name: "Holidays", url: "https://example.com/h.ics", host: "example.com")]
        s.reservesDockSpace = true
        s.appVolumes = ["com.apple.Music": UtilAppVolumeLevel(volume: 0.4, muted: false)]
        s.appVolumeRemember = false
        s.floatingOrigins = ["D": CGPointCodable(x: 12, y: 34)]
        store.settings = s
        store.newProfile(named: "Focus")
        store.addWidget(.todo, config: ["items": #"[{"id":"6F0E8B47-6C1B-4C59-9A47-2B1D4C3A0E11","title":"Write tests","created":800000000}]"#])
        store.addWidget(.space, config: ["width": "48"])
        store.updateWidget(store.activeProfile.widgets.last!.id) { $0.visibility = .lowBattery }

        Behaviour.withPersistence { store.saveNow() }
        await Behaviour.wait { (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(DockState.self, from: $0) } == store.dockState }

        let reopened = AppStore(stateFile: file)
        #expect(reopened.settings == store.settings)
        #expect(reopened.profiles == store.profiles)
        #expect(reopened.activeProfileID == store.activeProfileID && reopened.activeProfile.name == "Focus")
        #expect(CalTodoStore.items(reopened.activeProfile.widgets.first).map(\.title) == ["Write tests"])
        #expect(reopened.palette.isLight && abs(reopened.metrics.tileHeight - 77.5) < 1e-9)
    }

    @Test func aStateFileFromTheFirstReleaseStillLoads() throws {
        defer { cleanUp() }
        let file = folder.appendingPathComponent("state.json")
        try Data(Self.firstRelease.utf8).write(to: file)
        let store = AppStore(stateFile: file)
        let s = store.settings
        #expect(store.profiles.map(\.name) == ["Desk", "Travel"])
        #expect(store.activeProfileID == UUID(uuidString: "0A3E6C1D-5B7F-4E2A-9C8D-1F2E3D4C5B6A"))
        #expect(s.dockStyle == .lightGlass && s.cornerRadius == 12 && s.scenario == .swapBottom && s.language == .en)
        #expect(s.temperatureUnit == .celsius && s.displays.first?.displayName == "Studio")
        // Options added later fall back to their defaults.
        #expect(s.calendarFeeds == nil && !s.reservesDockSpace && !s.reservesAfterDragging)
        #expect(!s.assistantEnabled && !s.assistantAllowsChanges && s.appVolumes == nil && s.remembersAppVolumes)
        #expect(store.activeProfile.widgets.map(\.kind) == [.timeHero, .calculator])
        #expect(store.activeProfile.widgets[0].visibility == .always)
    }

    @Test func unreadableOrInconsistentFilesFallBackSafely() throws {
        defer { cleanUp() }
        let file = folder.appendingPathComponent("state.json")
        try Data("{ not json".utf8).write(to: file)
        var store = AppStore(stateFile: file)
        #expect(store.settings == CoolDock.Settings() && store.profiles.map(\.name) == ["Home", "Work", "System"])

        var state = DockState.fresh()
        state.activeProfileID = UUID() // points nowhere
        try JSONEncoder().encode(state).write(to: file)
        store = AppStore(stateFile: file)
        #expect(store.activeProfileID == state.profiles[0].id)

        state.profiles = []
        try JSONEncoder().encode(state).write(to: file)
        store = AppStore(stateFile: file)
        #expect(store.profiles.count == 3, "no profiles: start from the defaults")
    }

    /// state.json as the first release (9e30f0a) wrote it: no calendar feeds, Reserve Dock Space, AI Assistant or
    /// App Volume keys, the old Light Glass default and 12 pt corners.
    static let firstRelease = """
    {
      "activeProfileID" : "0A3E6C1D-5B7F-4E2A-9C8D-1F2E3D4C5B6A",
      "profiles" : [
        { "id" : "0A3E6C1D-5B7F-4E2A-9C8D-1F2E3D4C5B6A", "name" : "Desk", "symbol" : "house",
          "widgets" : [
            { "id" : "11111111-2222-3333-4444-555555555555", "kind" : "timeHero", "config" : {}, "visibility" : "always" },
            { "id" : "66666666-7777-8888-9999-AAAAAAAAAAAA", "kind" : "calculator", "config" : {}, "visibility" : "always" }
          ] },
        { "id" : "B1C2D3E4-F5A6-4B7C-8D9E-0F1A2B3C4D5E", "name" : "Travel", "symbol" : "airplane", "widgets" : [] }
      ],
      "settings" : {
        "alignment" : "center", "animations" : true, "appTheme" : "auto", "calendarSystem" : "automatic", "clockStyle" : "automatic",
        "cornerRadius" : 12, "digitStyle" : "automatic", "displays" : [ { "attached" : true, "builtIn" : false, "customName" : "Studio",
          "id" : "37D8832A-2D66-02CA-B9F7-8F30A301B230", "lastSeen" : 800000000, "name" : "DELL U2720Q" } ],
        "dockScale" : 1, "dockStyle" : "lightGlass", "dragAppsToRearrange" : false, "dragToSwitchProfiles" : true, "edgeDistance" : 8,
        "fixedPosition" : "bottomCenter", "floatingOrigins" : {}, "hideDelay" : 0, "hideDuringFullscreen" : true, "hideOnWindowHover" : false,
        "iconStyle" : "standard", "language" : "en", "launchAtLogin" : false, "monochrome" : false, "onboardingDone" : true,
        "openFoldersInFinder" : false, "overflow" : "adapt", "pauseWhenHidden" : true, "profileHotKeyModifiers" : 6400,
        "profileHotKeysEnabled" : true, "reduceTransparency" : false, "runningApps" : "hidden", "runningAppsCollapsed" : false,
        "scenario" : "swapBottom", "screensMode" : "one", "shadow" : true, "showAppLabelsOnHover" : true, "showDelay" : 0,
        "showMenuBarIcon" : true, "showProfileSwitcher" : true, "showRunningIndicators" : true, "systemSampleInterval" : 2,
        "temperatureUnit" : "celsius", "tileBackgrounds" : true, "toggleHotKey" : { "enabled" : true, "keyCode" : 2, "modifiers" : 6400 },
        "triggerSize" : 3, "useEstedad" : true, "widgetSpacing" : 6, "widgetSurface" : "glass"
      }
    }
    """
}
