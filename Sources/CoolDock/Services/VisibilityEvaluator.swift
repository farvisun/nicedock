import AppKit
import Observation

/// Evaluates conditional visibility rules. Services are only started for rules actually in use.
@MainActor
final class VisibilityEvaluator {
    static let shared = VisibilityEvaluator()
    private var monitorToken: String?
    private var calendarToken: String?

    func isVisible(_ w: WidgetInstance) -> Bool {
        switch w.visibility {
        case .always:
            return true
        case .whilePlaying:
            NowPlayingService.shared.start()
            return NowPlayingService.shared.isPlaying
        case .cpuHigh:
            ensureMonitor()
            return SystemMonitor.shared.cpu > 0.7
        case .memoryHigh:
            ensureMonitor()
            return SystemMonitor.shared.memory > 0.8
        case .temperatureHigh:
            ensureMonitor()
            let t = SystemMonitor.shared
            return t.thermal == .serious || t.thermal == .critical || (t.temperature ?? 0) > 85
        case .lowBattery:
            ensureMonitor()
            let m = SystemMonitor.shared
            return m.hasBattery && m.battery < 0.2 && !m.charging
        case .beforeMeetings:
            ensureCalendar()
            return CalendarService.shared.meetingSoon()
        case .inZoomMeeting:
            return ZoomDetector.shared.inMeeting
        case .whileRunning:
            let path = w.string("path")
            return RunningApps.shared.apps.contains { $0.bundleURL?.path == path }
        }
    }

    private func ensureMonitor() {
        guard monitorToken == nil else { return }
        let t = "visibility"
        SystemMonitor.shared.subscribe(t)
        monitorToken = t
    }

    private func ensureCalendar() {
        guard calendarToken == nil else { return }
        calendarToken = "visibility"
        CalendarDemand.events.subscribe("visibility")
    }
}

/// Detects an active Zoom call by its meeting window (no permissions needed for window titles of on-screen windows? Owner names only).
@Observable
@MainActor
final class ZoomDetector {
    static let shared = ZoomDetector()
    private(set) var inMeeting = false
    private(set) var meetingStart: Date?
    @ObservationIgnored private var timer: Timer?

    init() {
        let t = Timer(timeInterval: 5, repeats: true) { _ in MainActor.assumeIsolated { ZoomDetector.shared.check() } }
        t.tolerance = 2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func check() {
        guard Script.isRunning("us.zoom.xos") else {
            if inMeeting { inMeeting = false; meetingStart = nil }
            return
        }
        let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        // Zoom's meeting window is the only large zoom.us window with layer 0 besides the home window; the CptHost helper runs only during calls.
        let callHelper = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "us.zoom.CptHost" || ($0.localizedName ?? "") == "CptHost" }
        let zoomWindows = list.filter { ($0[kCGWindowOwnerName as String] as? String) == "zoom.us" && ($0[kCGWindowLayer as String] as? Int) == 0 }
        let now = callHelper || zoomWindows.contains { ($0[kCGWindowName as String] as? String)?.contains("Zoom Meeting") == true }
        if now != inMeeting {
            inMeeting = now
            meetingStart = now ? Date() : nil
        }
    }
}

/// Running GUI apps, kept current via workspace notifications.
@Observable
@MainActor
final class RunningApps {
    static let shared = RunningApps()
    private(set) var apps: [NSRunningApplication] = []
    private(set) var frontmost: pid_t = 0

    init() {
        reload()
        let wnc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification, NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification] {
            wnc.addObserver(forName: name, object: nil, queue: .main) { _ in MainActor.assumeIsolated { RunningApps.shared.reload() } }
        }
    }

    func reload() {
        let me = ProcessInfo.processInfo.processIdentifier
        let fresh = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.processIdentifier != me }
        if fresh.map(\.processIdentifier) != apps.map(\.processIdentifier) { apps = fresh }
        frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
    }

    func isRunning(path: String) -> Bool {
        let p = (path as NSString).expandingTildeInPath
        return apps.contains { $0.bundleURL?.path == p }
    }

    func app(path: String) -> NSRunningApplication? {
        let p = (path as NSString).expandingTildeInPath
        return apps.first { $0.bundleURL?.path == p }
    }
}
