import Foundation
import SwiftUI

/// Every widget CoolDock can place in the dock. Raw values are persisted — never rename.
enum WidgetKind: String, Codable, CaseIterable, Identifiable {
    // Apps & files
    case app, appFolder, applications, trash, folder, downloads, recentFiles, fileShelf, airDrop, dropbox
    case bookmarks, searchWeb, findFiles, appSwitcher, runningApps
    // Clocks
    case clockDigital, clockSeconds, clockDate, timeHero, dateTile, dayDate, dateTimeWeather, flipClock
    case analogDark, analogLight, worldClock, pixelClock
    case timer, stopwatch, pomodoro, drinkWater, posture
    // Calendar
    case calendarToday, agenda, weekStrip, nextMeeting, zoomMeeting, dayProgress, monthProgress, yearProgress, progressRing
    // Reminders & tasks
    case reminders, todo, linear
    // Weather
    case weatherCompact, weatherHero, weatherLocation, forecastDays, weatherToday, weatherCondition, forecastHourly, sunriseSunset, wind
    // System
    case batteryRing, cpuRing, memoryRing, storageRing, temperatureRing, cpuGraph, networkGraph, devicesBattery
    // Controls & tools
    case audioControls, quickToggles, clipboard, screenshots, recentScreenshots, voiceMemo, emoji
    case colorPicker, converter, calculator, separator, space
    // Media & photos
    case nowPlaying, nowPlayingHero, backgroundSounds, youtubeVideo, recentPhoto, wallpaper
    // Mail, notes, phone
    case mail, mailLatest, notes, quickContacts
    // Stocks & crypto
    case stockQuote, stockChart, stockWatchlist, cryptoQuote, cryptoChart, cryptoWatchlist
    // Finance & commerce
    case polarRevenue, stripeRevenue, dodoRevenue, shopifyChart, shopifyToday, shopifyOverview
    // Analytics & developer
    case plausible, simpleAnalytics, dataFast, visitorsChart, dubStats, resendStats, githubContributions, supabase
    // Social
    case socialX, socialTikTok, socialYouTube
    // AI
    case aiUsage

    var id: String { rawValue }
    var spec: WidgetSpec { WidgetCatalog.spec(self) }
}

struct WidgetSpec {
    let category: WidgetCategory
    let title: String
    let summary: String
    let symbol: String
    let width: CGFloat
    var fields: [ConfigField] = []
    var defaults: [String: String] = [:]
    var visibility: [VisibilityRule] = []
    var connected: Bool = false
    /// Widgets with no tile chrome (app icons, separators).
    var bare: Bool = false
    var browsable: Bool = true

    var localizedTitle: String { L(title) }
    var localizedSummary: String { L(summary) }
}

enum WidgetCatalog {
    static let refreshChoices = [
        ConfigOption(value: "300", title: "5 min"), ConfigOption(value: "900", title: "15 min"),
        ConfigOption(value: "1800", title: "30 min"), ConfigOption(value: "3600", title: "1 h")
    ]
    static let rangeChoices = [
        ConfigOption(value: "1d", title: "Today"), ConfigOption(value: "7d", title: "Last 7 days"),
        ConfigOption(value: "30d", title: "Last 30 days")
    ]
    static let currencyChoices = ["USD", "EUR", "GBP", "IRR", "TRY", "AED", "JPY", "CNY", "CAD", "AUD", "CHF", "INR", "RUB", "SAR", "BTC"]
        .map { ConfigOption(value: $0, title: $0) }

    static func tokenField(_ placeholder: String = "Paste API token") -> ConfigField {
        ConfigField(key: "token", title: "API Token", type: .secret(placeholder: placeholder), help: "Stored in your macOS Keychain.")
    }
    static let cityField = ConfigField(key: "city", title: "Location", type: .city, help: "Leave empty to use your current location.")
    static let accentField = ConfigField(key: "color", title: "Accent Color", type: .color)

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    static func spec(_ kind: WidgetKind) -> WidgetSpec {
        switch kind {
        // MARK: Apps & files
        case .app:
            return WidgetSpec(category: .apps, title: "App", summary: "Launch or focus a favorite app.", symbol: "app", width: 62,
                              fields: [ConfigField(key: "path", title: "Application", type: .app)], bare: true)
        case .appFolder:
            return WidgetSpec(category: .apps, title: "App Folder", summary: "Group apps in one tile with an in-Dock gallery.", symbol: "square.grid.2x2", width: 62,
                              fields: [ConfigField(key: "name", title: "Name", type: .text(placeholder: "Folder")),
                                       ConfigField(key: "apps", title: "Apps", type: .apps),
                                       ConfigField(key: "color", title: "Folder Color", type: .color)],
                              defaults: ["name": "Favorites", "apps": "/System/Applications/Finder.app\n/System/Applications/Music.app\n/System/Applications/Photos.app\n/System/Applications/Mail.app"])
        case .applications:
            return WidgetSpec(category: .apps, title: "Applications", summary: "Browse every installed app.", symbol: "square.grid.3x3.fill", width: 62, bare: true)
        case .trash:
            return WidgetSpec(category: .apps, title: "Trash", summary: "Drop files to delete them; empty the Trash.", symbol: "trash", width: 62, bare: true)
        case .folder:
            return WidgetSpec(category: .folders, title: "Folder", summary: "Browse a folder in an in-Dock gallery.", symbol: "folder", width: 62,
                              fields: [ConfigField(key: "path", title: "Folder", type: .folder),
                                       ConfigField(key: "display", title: "Folder Display", type: .choice([ConfigOption(value: "icon", title: "Folder Icon"), ConfigOption(value: "stack", title: "Stack Preview")])),
                                       ConfigField(key: "color", title: "Folder Color", type: .color)],
                              defaults: ["path": "~/Documents", "display": "icon"], bare: true)
        case .downloads:
            return WidgetSpec(category: .folders, title: "Downloads", summary: "Your latest downloads one click away.", symbol: "arrow.down.circle", width: 62)
        case .recentFiles:
            return WidgetSpec(category: .folders, title: "Recent Files", summary: "Files you opened recently.", symbol: "clock.arrow.circlepath", width: 62)
        case .fileShelf:
            return WidgetSpec(category: .folders, title: "File Shelf", summary: "Hold files temporarily, then drag them anywhere.", symbol: "tray.and.arrow.down", width: 62)
        case .airDrop:
            return WidgetSpec(category: .folders, title: "AirDrop", summary: "Drop files to share them via AirDrop.", symbol: "airplayaudio", width: 62)
        case .dropbox:
            return WidgetSpec(category: .folders, title: "Dropbox", summary: "Your Dropbox folder; drop files to upload.", symbol: "shippingbox", width: 62,
                              fields: [ConfigField(key: "path", title: "Dropbox Folder", type: .folder)], defaults: ["path": "~/Library/CloudStorage/Dropbox"])
        case .bookmarks:
            return WidgetSpec(category: .utilities, title: "Bookmarks", summary: "Your favorite links as favicons.", symbol: "bookmark", width: 146,
                              fields: [ConfigField(key: "urls", title: "Links (one per line)", type: .multiline(placeholder: "https://example.com"))],
                              defaults: ["urls": "https://github.com\nhttps://news.ycombinator.com\nhttps://www.youtube.com\nhttps://mail.google.com"])
        case .searchWeb:
            return WidgetSpec(category: .utilities, title: "Search Web", summary: "Search the web straight from the Dock.", symbol: "magnifyingglass", width: 208,
                              fields: [ConfigField(key: "engine", title: "Search Engine", type: .choice([
                                  ConfigOption(value: "google", title: "Google"), ConfigOption(value: "duckduckgo", title: "DuckDuckGo"),
                                  ConfigOption(value: "bing", title: "Bing"), ConfigOption(value: "perplexity", title: "Perplexity"),
                                  ConfigOption(value: "chatgpt", title: "ChatGPT"), ConfigOption(value: "claude", title: "Claude"),
                                  ConfigOption(value: "kagi", title: "Kagi")]))],
                              defaults: ["engine": "google"])
        case .findFiles:
            return WidgetSpec(category: .folders, title: "Find Files", summary: "Spotlight file search in the Dock.", symbol: "doc.text.magnifyingglass", width: 207)
        case .appSwitcher:
            return WidgetSpec(category: .apps, title: "App Switcher", summary: "Jump between running apps.", symbol: "square.grid.2x2", width: 62)
        case .runningApps:
            return WidgetSpec(category: .apps, title: "Running Apps", summary: "Live running apps with indicators.", symbol: "dock.rectangle", width: 62, bare: true, browsable: false)

        // MARK: Clocks
        case .clockDigital:
            return WidgetSpec(category: .clocks, title: "Clock", summary: "Large digital time.", symbol: "clock", width: 105)
        case .clockSeconds:
            return WidgetSpec(category: .clocks, title: "Clock with Seconds", summary: "Time with live seconds.", symbol: "clock.badge", width: 135)
        case .clockDate:
            return WidgetSpec(category: .clocks, title: "Time & Date", summary: "Time above a short date.", symbol: "clock.fill", width: 104)
        case .timeHero:
            return WidgetSpec(category: .clocks, title: "Time Card", summary: "Centered time and date.", symbol: "clock.circle", width: 92)
        case .dateTile:
            return WidgetSpec(category: .clocks, title: "Date", summary: "Day number and month.", symbol: "calendar.day.timeline.left", width: 70)
        case .dayDate:
            return WidgetSpec(category: .clocks, title: "Day & Date", summary: "Weekday above the date.", symbol: "textformat", width: 101)
        case .dateTimeWeather:
            return WidgetSpec(category: .clocks, title: "Date, Time & Weather", summary: "Date, time and current weather together.", symbol: "cloud.sun.circle", width: 142,
                              fields: [cityField])
        case .flipClock:
            return WidgetSpec(category: .clocks, title: "Flip Clock", summary: "Retro split-flap digits.", symbol: "rectangle.split.2x1", width: 164)
        case .analogDark:
            return WidgetSpec(category: .clocks, title: "Analog Clock", summary: "Minimal dark analog face.", symbol: "clock", width: 81,
                              fields: [ConfigField(key: "seconds", title: "Second Hand", type: .toggle)], defaults: ["seconds": "1"])
        case .analogLight:
            return WidgetSpec(category: .clocks, title: "Analog Clock (Light)", summary: "Classic white analog face.", symbol: "clock.fill", width: 71,
                              fields: [ConfigField(key: "seconds", title: "Second Hand", type: .toggle)], defaults: ["seconds": "1"])
        case .worldClock:
            return WidgetSpec(category: .clocks, title: "World Clock", summary: "Time in another city.", symbol: "globe", width: 120,
                              fields: [ConfigField(key: "zone", title: "Time Zone", type: .text(placeholder: "Asia/Tehran")),
                                       ConfigField(key: "label", title: "Label", type: .text(placeholder: "Tehran"))],
                              defaults: ["zone": "Asia/Tehran", "label": "Tehran"])
        case .pixelClock:
            return WidgetSpec(category: .clocks, title: "Pixel Clock", summary: "Dot-matrix time display.", symbol: "circle.grid.3x3", width: 150,
                              fields: [accentField], defaults: ["color": "#30D158"])
        case .timer:
            return WidgetSpec(category: .clocks, title: "Timer", summary: "Countdown timer with a progress border.", symbol: "timer", width: 155,
                              fields: [ConfigField(key: "minutes", title: "Duration", type: .number(min: 1, max: 240, step: 1, unit: "min"))],
                              defaults: ["minutes": "5"])
        case .stopwatch:
            return WidgetSpec(category: .clocks, title: "Stopwatch", summary: "Start, pause and reset.", symbol: "stopwatch", width: 175)
        case .pomodoro:
            return WidgetSpec(category: .clocks, title: "Pomodoro", summary: "Focus and break rounds.", symbol: "brain.head.profile", width: 175,
                              fields: [ConfigField(key: "focus", title: "Focus", type: .number(min: 5, max: 120, step: 5, unit: "min")),
                                       ConfigField(key: "short", title: "Short Break", type: .number(min: 1, max: 30, step: 1, unit: "min")),
                                       ConfigField(key: "long", title: "Long Break", type: .number(min: 5, max: 60, step: 5, unit: "min")),
                                       ConfigField(key: "rounds", title: "Rounds", type: .number(min: 1, max: 12, step: 1, unit: "")),
                                       ConfigField(key: "sound", title: "Play Sound", type: .toggle)],
                              defaults: ["focus": "25", "short": "5", "long": "15", "rounds": "4", "sound": "1"])
        case .drinkWater:
            return WidgetSpec(category: .clocks, title: "Drink Water", summary: "Hydration reminders on a schedule.", symbol: "drop", width: 150,
                              fields: [ConfigField(key: "interval", title: "Remind Every", type: .number(min: 10, max: 180, step: 5, unit: "min"))],
                              defaults: ["interval": "30"])
        case .posture:
            return WidgetSpec(category: .clocks, title: "Posture", summary: "Gentle reminders to sit up straight.", symbol: "figure.stand", width: 150,
                              fields: [ConfigField(key: "interval", title: "Remind Every", type: .number(min: 10, max: 180, step: 5, unit: "min"))],
                              defaults: ["interval": "45"])

        // MARK: Calendar
        case .calendarToday:
            return WidgetSpec(category: .calendar, title: "Today's Events", summary: "Today's events with the calendar icon.", symbol: "calendar", width: 225,
                              visibility: [.beforeMeetings])
        case .agenda:
            return WidgetSpec(category: .calendar, title: "Agenda", summary: "Date and upcoming events.", symbol: "list.bullet.rectangle", width: 225)
        case .weekStrip:
            return WidgetSpec(category: .calendar, title: "Week", summary: "This week at a glance with weather.", symbol: "calendar.badge.clock", width: 220,
                              fields: [cityField])
        case .nextMeeting:
            return WidgetSpec(category: .calendar, title: "Next Meeting", summary: "Next meeting with a one-click join.", symbol: "video", width: 220,
                              visibility: [.beforeMeetings])
        case .zoomMeeting:
            return WidgetSpec(category: .calendar, title: "Zoom Meeting", summary: "Meeting timer while Zoom is in a call.", symbol: "video.circle", width: 150,
                              defaults: [:], visibility: [.inZoomMeeting])
        case .dayProgress:
            return WidgetSpec(category: .calendar, title: "Day Progress", summary: "How much of today has passed.", symbol: "circle.dotted", width: 114)
        case .monthProgress:
            return WidgetSpec(category: .calendar, title: "Month Progress", summary: "How much of this month has passed.", symbol: "circle.grid.3x3", width: 115)
        case .yearProgress:
            return WidgetSpec(category: .calendar, title: "Year Progress", summary: "How much of this year has passed.", symbol: "circle.grid.3x3.fill", width: 130)
        case .progressRing:
            return WidgetSpec(category: .calendar, title: "Progress Ring", summary: "Day, week, month or year as a ring.", symbol: "circle.circle", width: 62,
                              fields: [ConfigField(key: "period", title: "Period", type: .choice([
                                  ConfigOption(value: "day", title: "Day"), ConfigOption(value: "week", title: "Week"),
                                  ConfigOption(value: "month", title: "Month"), ConfigOption(value: "year", title: "Year")])),
                                       accentField],
                              defaults: ["period": "day", "color": "#30D158"])

        // MARK: Reminders & tasks
        case .reminders:
            return WidgetSpec(category: .reminders, title: "Reminders", summary: "Upcoming reminders; click to complete.", symbol: "checklist", width: 196)
        case .todo:
            return WidgetSpec(category: .reminders, title: "Todo", summary: "A private local todo list.", symbol: "checkmark.circle", width: 196)
        case .linear:
            return WidgetSpec(category: .reminders, title: "Linear", summary: "Your assigned Linear issues.", symbol: "line.3.diagonal", width: 220,
                              fields: [tokenField("lin_api_…")], connected: true)

        // MARK: Weather
        case .weatherCompact:
            return WidgetSpec(category: .weather, title: "Weather", summary: "Current conditions.", symbol: "cloud.sun", width: 90, fields: [cityField])
        case .weatherHero:
            return WidgetSpec(category: .weather, title: "Weather & Forecast", summary: "Today plus the next three days.", symbol: "cloud.sun.rain", width: 200, fields: [cityField])
        case .weatherLocation:
            return WidgetSpec(category: .weather, title: "Weather Details", summary: "Location, wind and precipitation.", symbol: "location", width: 217, fields: [cityField])
        case .forecastDays:
            return WidgetSpec(category: .weather, title: "Daily Forecast", summary: "Four-day forecast.", symbol: "calendar", width: 188, fields: [cityField])
        case .weatherToday:
            return WidgetSpec(category: .weather, title: "Today & Forecast", summary: "Big temperature with three days.", symbol: "thermometer.sun", width: 202, fields: [cityField])
        case .weatherCondition:
            return WidgetSpec(category: .weather, title: "Conditions", summary: "Large condition icon.", symbol: "cloud.rain", width: 94, fields: [cityField])
        case .forecastHourly:
            return WidgetSpec(category: .weather, title: "Hourly Forecast", summary: "The next hours.", symbol: "clock.badge", width: 266, fields: [cityField])
        case .sunriseSunset:
            return WidgetSpec(category: .weather, title: "Sunrise & Sunset", summary: "Sun arc with sunrise and sunset.", symbol: "sunrise", width: 226, fields: [cityField])
        case .wind:
            return WidgetSpec(category: .weather, title: "Wind", summary: "Wind speed, direction and gusts.", symbol: "wind", width: 194, fields: [cityField])

        // MARK: System
        case .batteryRing:
            return WidgetSpec(category: .system, title: "Battery", summary: "Battery level and charging.", symbol: "battery.75", width: 70, visibility: [.lowBattery])
        case .cpuRing:
            return WidgetSpec(category: .system, title: "CPU", summary: "Processor load.", symbol: "cpu", width: 70, visibility: [.cpuHigh])
        case .memoryRing:
            return WidgetSpec(category: .system, title: "Memory", summary: "Memory pressure.", symbol: "memorychip", width: 70, visibility: [.memoryHigh])
        case .storageRing:
            return WidgetSpec(category: .system, title: "Storage", summary: "Free disk space in GB.", symbol: "internaldrive", width: 70)
        case .temperatureRing:
            return WidgetSpec(category: .system, title: "Temperature", summary: "Thermal state of your Mac.", symbol: "thermometer.medium", width: 70, visibility: [.temperatureHigh])
        case .cpuGraph:
            return WidgetSpec(category: .system, title: "CPU History", summary: "Live CPU graph.", symbol: "waveform.path.ecg", width: 150, visibility: [.cpuHigh])
        case .networkGraph:
            return WidgetSpec(category: .system, title: "Network", summary: "Download and upload speed.", symbol: "arrow.up.arrow.down", width: 166)
        case .devicesBattery:
            return WidgetSpec(category: .system, title: "Devices Battery", summary: "Battery of connected keyboards, mice and headphones.", symbol: "keyboard", width: 160)

        // MARK: Controls & tools
        case .audioControls:
            return WidgetSpec(category: .controls, title: "Audio", summary: "Volume and output device switching.", symbol: "speaker.wave.2", width: 224)
        case .quickToggles:
            return WidgetSpec(category: .controls, title: "Quick Toggles", summary: "Wi-Fi, Bluetooth, appearance and more.", symbol: "switch.2", width: 265,
                              fields: [ConfigField(key: "items", title: "Toggles", type: .multiline(placeholder: "wifi\nbluetooth\ndarkMode\nkeepAwake\nhideDesktop")),],
                              defaults: ["items": "wifi\nbluetooth\ndarkMode\nkeepAwake\nkeyboardLock"])
        case .clipboard:
            return WidgetSpec(category: .controls, title: "Clipboard", summary: "Clipboard history.", symbol: "doc.on.clipboard", width: 62)
        case .screenshots:
            return WidgetSpec(category: .controls, title: "Screenshots", summary: "Capture window, area or screen.", symbol: "camera.viewfinder", width: 148)
        case .recentScreenshots:
            return WidgetSpec(category: .controls, title: "Recent Screenshots", summary: "Your latest screenshots.", symbol: "clock.arrow.circlepath", width: 62)
        case .voiceMemo:
            return WidgetSpec(category: .controls, title: "Voice Memo", summary: "Record audio notes in one click.", symbol: "mic", width: 70)
        case .emoji:
            return WidgetSpec(category: .controls, title: "Emoji", summary: "Favorite emoji, copied in one click.", symbol: "face.smiling", width: 146,
                              fields: [ConfigField(key: "emoji", title: "Emoji", type: .text(placeholder: "😂✨✅🔥🥹🙏💡🚀❤️"))],
                              defaults: ["emoji": "😂✨✅🔥🥹🙏💡🚀❤️"])
        case .colorPicker:
            return WidgetSpec(category: .utilities, title: "Color Picker", summary: "Pick colors from anywhere on screen.", symbol: "eyedropper", width: 65)
        case .converter:
            return WidgetSpec(category: .utilities, title: "Converter", summary: "Currency and unit conversion.", symbol: "arrow.left.arrow.right", width: 183,
                              fields: [ConfigField(key: "from", title: "From", type: .choice(currencyChoices)),
                                       ConfigField(key: "to", title: "To", type: .choice(currencyChoices))],
                              defaults: ["from": "USD", "to": "EUR", "amount": "500"])
        case .calculator:
            return WidgetSpec(category: .utilities, title: "Calculator", summary: "Type math, get answers.", symbol: "plus.forwardslash.minus", width: 183)
        case .separator:
            return WidgetSpec(category: .utilities, title: "Separator", summary: "A thin divider.", symbol: "line.diagonal", width: 9, bare: true)
        case .space:
            return WidgetSpec(category: .utilities, title: "Space", summary: "Empty space between widgets.", symbol: "arrow.left.and.right", width: 24,
                              fields: [ConfigField(key: "width", title: "Width", type: .number(min: 4, max: 200, step: 4, unit: "pt"))],
                              defaults: ["width": "24"], bare: true)

        // MARK: Media & photos
        case .nowPlaying:
            return WidgetSpec(category: .media, title: "Now Playing", summary: "Music and Spotify controls.", symbol: "music.note", width: 241, visibility: [.whilePlaying])
        case .nowPlayingHero:
            return WidgetSpec(category: .media, title: "Now Playing (Large)", summary: "Large artwork with controls.", symbol: "play.square", width: 232, visibility: [.whilePlaying])
        case .backgroundSounds:
            return WidgetSpec(category: .media, title: "Background Sounds", summary: "Rain, ocean and noise to focus.", symbol: "waveform", width: 64,
                              fields: [ConfigField(key: "sound", title: "Sound", type: .choice([
                                  ConfigOption(value: "rain", title: "Rain"), ConfigOption(value: "ocean", title: "Ocean"),
                                  ConfigOption(value: "brown", title: "Brown Noise"), ConfigOption(value: "pink", title: "Pink Noise"),
                                  ConfigOption(value: "white", title: "White Noise")]))],
                              defaults: ["sound": "rain"])
        case .youtubeVideo:
            return WidgetSpec(category: .media, title: "YouTube Video", summary: "Keep a video one click away.", symbol: "play.rectangle", width: 120,
                              fields: [ConfigField(key: "url", title: "Video URL", type: .text(placeholder: "https://youtu.be/…"))],
                              defaults: ["url": "https://www.youtube.com/watch?v=4GB3XQaYejk"])
        case .recentPhoto:
            return WidgetSpec(category: .photos, title: "Recent Photo", summary: "Your latest photo.", symbol: "photo", width: 62)
        case .wallpaper:
            return WidgetSpec(category: .photos, title: "Wallpaper", summary: "Shuffle wallpapers from a folder.", symbol: "photo.on.rectangle", width: 100,
                              fields: [ConfigField(key: "path", title: "Wallpaper Folder", type: .folder)],
                              defaults: ["path": "/System/Library/Desktop Pictures"])

        // MARK: Mail, notes, phone
        case .mail:
            return WidgetSpec(category: .mail, title: "Mail", summary: "Unread count and quick compose.", symbol: "envelope", width: 229)
        case .mailLatest:
            return WidgetSpec(category: .mail, title: "Latest Mail", summary: "Newest unread message.", symbol: "envelope.badge", width: 278)
        case .notes:
            return WidgetSpec(category: .notes, title: "Notes", summary: "Latest note and quick capture.", symbol: "note.text", width: 225)
        case .quickContacts:
            return WidgetSpec(category: .phone, title: "Quick Contacts", summary: "Call, message or FaceTime favorites.", symbol: "person.crop.circle", width: 163,
                              fields: [ConfigField(key: "contacts", title: "Contacts", type: .contacts)])

        // MARK: Stocks & crypto
        case .stockQuote:
            return WidgetSpec(category: .stocks, title: "Stock", summary: "Price and daily change.", symbol: "chart.line.uptrend.xyaxis", width: 173,
                              fields: [ConfigField(key: "symbol", title: "Symbol", type: .text(placeholder: "AAPL"))], defaults: ["symbol": "AAPL"])
        case .stockChart:
            return WidgetSpec(category: .stocks, title: "Stock Chart", summary: "Intraday chart.", symbol: "chart.xyaxis.line", width: 149,
                              fields: [ConfigField(key: "symbol", title: "Symbol", type: .text(placeholder: "AAPL"))], defaults: ["symbol": "AAPL"])
        case .stockWatchlist:
            return WidgetSpec(category: .stocks, title: "Watchlist", summary: "Three symbols at a glance.", symbol: "list.number", width: 224,
                              fields: [ConfigField(key: "symbols", title: "Symbols (one per line)", type: .multiline(placeholder: "AAPL"))],
                              defaults: ["symbols": "AAPL\nMSFT\nNVDA"])
        case .cryptoQuote:
            return WidgetSpec(category: .crypto, title: "Crypto", summary: "Coin price and 24h change.", symbol: "bitcoinsign.circle", width: 173,
                              fields: [ConfigField(key: "symbol", title: "Coin", type: .text(placeholder: "BTC"))], defaults: ["symbol": "BTC"])
        case .cryptoChart:
            return WidgetSpec(category: .crypto, title: "Crypto Chart", summary: "24h price chart.", symbol: "chart.xyaxis.line", width: 149,
                              fields: [ConfigField(key: "symbol", title: "Coin", type: .text(placeholder: "ETH"))], defaults: ["symbol": "ETH"])
        case .cryptoWatchlist:
            return WidgetSpec(category: .crypto, title: "Crypto Watchlist", summary: "Three coins at a glance.", symbol: "list.number", width: 224,
                              fields: [ConfigField(key: "symbols", title: "Coins (one per line)", type: .multiline(placeholder: "BTC"))],
                              defaults: ["symbols": "BTC\nETH\nSOL"])

        // MARK: Finance & commerce
        case .polarRevenue:
            return WidgetSpec(category: .finance, title: "Polar Revenue", summary: "Net revenue from Polar.", symbol: "dollarsign.circle", width: 145,
                              fields: [tokenField("polar_oat_…"), ConfigField(key: "range", title: "Range", type: .choice(rangeChoices))],
                              defaults: ["range": "30d"], connected: true)
        case .stripeRevenue:
            return WidgetSpec(category: .finance, title: "Stripe Revenue", summary: "Net revenue from Stripe.", symbol: "creditcard", width: 145,
                              fields: [tokenField("rk_live_…"), ConfigField(key: "range", title: "Range", type: .choice(rangeChoices))],
                              defaults: ["range": "30d"], connected: true)
        case .dodoRevenue:
            return WidgetSpec(category: .finance, title: "Dodo Payments", summary: "Net revenue from Dodo Payments.", symbol: "banknote", width: 146,
                              fields: [tokenField(), ConfigField(key: "range", title: "Range", type: .choice(rangeChoices))],
                              defaults: ["range": "30d"], connected: true)
        case .shopifyChart:
            return WidgetSpec(category: .commerce, title: "Shopify Trend", summary: "Sales and orders with a trend line.", symbol: "chart.line.uptrend.xyaxis", width: 234,
                              fields: shopifyFields, defaults: ["range": "7d"], connected: true)
        case .shopifyToday:
            return WidgetSpec(category: .commerce, title: "Shopify Today", summary: "Today's total sales.", symbol: "bag", width: 223,
                              fields: shopifyFields, defaults: ["range": "1d"], connected: true)
        case .shopifyOverview:
            return WidgetSpec(category: .commerce, title: "Shopify Overview", summary: "Sales, orders and average order.", symbol: "bag.fill", width: 247,
                              fields: shopifyFields, defaults: ["range": "7d"], connected: true)

        // MARK: Analytics & developer
        case .plausible:
            return WidgetSpec(category: .analytics, title: "Plausible", summary: "Visitors from Plausible Analytics.", symbol: "chart.bar", width: 146,
                              fields: [ConfigField(key: "site", title: "Site", type: .text(placeholder: "example.com")),
                                       ConfigField(key: "host", title: "Host", type: .text(placeholder: "https://plausible.io")),
                                       tokenField(), ConfigField(key: "range", title: "Range", type: .choice(rangeChoices))],
                              defaults: ["range": "7d", "host": "https://plausible.io"], connected: true)
        case .simpleAnalytics:
            return WidgetSpec(category: .analytics, title: "Simple Analytics", summary: "Visitors from Simple Analytics.", symbol: "chart.bar.xaxis", width: 145,
                              fields: [ConfigField(key: "site", title: "Site", type: .text(placeholder: "example.com")), tokenField("sa_api_key_…"),
                                       ConfigField(key: "range", title: "Range", type: .choice(rangeChoices))],
                              defaults: ["range": "7d"], connected: true)
        case .dataFast:
            return WidgetSpec(category: .analytics, title: "DataFast", summary: "Visitors and revenue from DataFast.", symbol: "chart.bar.doc.horizontal", width: 145,
                              fields: [tokenField(), ConfigField(key: "range", title: "Range", type: .choice(rangeChoices))],
                              defaults: ["range": "7d"], connected: true)
        case .visitorsChart:
            return WidgetSpec(category: .analytics, title: "Visitors Chart", summary: "Visitors with a trend line (Plausible).", symbol: "chart.line.uptrend.xyaxis", width: 233,
                              fields: [ConfigField(key: "site", title: "Site", type: .text(placeholder: "example.com")),
                                       ConfigField(key: "host", title: "Host", type: .text(placeholder: "https://plausible.io")),
                                       tokenField(), ConfigField(key: "range", title: "Range", type: .choice(rangeChoices))],
                              defaults: ["range": "7d", "host": "https://plausible.io"], connected: true)
        case .dubStats:
            return WidgetSpec(category: .analytics, title: "Dub", summary: "Clicks, leads and sales from Dub links.", symbol: "link", width: 194,
                              fields: [tokenField("dub_…"), ConfigField(key: "range", title: "Range", type: .choice(rangeChoices))],
                              defaults: ["range": "7d"], connected: true)
        case .resendStats:
            return WidgetSpec(category: .developer, title: "Resend", summary: "Emails sent and delivered.", symbol: "paperplane", width: 194,
                              fields: [tokenField("re_…")], connected: true)
        case .githubContributions:
            return WidgetSpec(category: .developer, title: "GitHub", summary: "Contributions, streak and activity grid.", symbol: "square.grid.4x3.fill", width: 140,
                              fields: [ConfigField(key: "user", title: "Username", type: .text(placeholder: "octocat")), tokenField("ghp_…")],
                              connected: true)
        case .supabase:
            return WidgetSpec(category: .developer, title: "Supabase", summary: "Project health and API requests.", symbol: "cylinder.split.1x2", width: 194,
                              fields: [ConfigField(key: "project", title: "Project Ref", type: .text(placeholder: "abcdefghijklmnop")), tokenField("sbp_…")],
                              connected: true)

        // MARK: Social
        case .socialX:
            return WidgetSpec(category: .social, title: "X Followers", summary: "Follower count on X.", symbol: "person.2", width: 130,
                              fields: [ConfigField(key: "user", title: "Username", type: .text(placeholder: "username")), tokenField("Bearer token")],
                              connected: true)
        case .socialTikTok:
            return WidgetSpec(category: .social, title: "TikTok Followers", summary: "Follower count on TikTok.", symbol: "music.note", width: 130,
                              fields: [tokenField("act.…")], connected: true)
        case .socialYouTube:
            return WidgetSpec(category: .social, title: "YouTube Subscribers", summary: "Subscriber count on YouTube.", symbol: "play.rectangle.fill", width: 130,
                              fields: [ConfigField(key: "channel", title: "Channel ID or @handle", type: .text(placeholder: "@handle")), tokenField("AIza…")],
                              connected: true)

        // MARK: AI
        case .aiUsage:
            return WidgetSpec(category: .ai, title: "AI Usage", summary: "Token usage for Claude Code, Codex and APIs.", symbol: "sparkles", width: 194,
                              fields: [ConfigField(key: "provider", title: "Provider", type: .choice([
                                  ConfigOption(value: "claudeCode", title: "Claude Code (local)"),
                                  ConfigOption(value: "codex", title: "Codex (local)"),
                                  ConfigOption(value: "anthropic", title: "Anthropic API (admin key)"),
                                  ConfigOption(value: "openai", title: "OpenAI API (admin key)")])),
                                       tokenField("Only for API providers"),
                                       ConfigField(key: "range", title: "Range", type: .choice(rangeChoices))],
                              defaults: ["provider": "claudeCode", "range": "7d"])
        }
    }

    static let shopifyFields: [ConfigField] = [
        ConfigField(key: "shop", title: "Store Domain", type: .text(placeholder: "store.myshopify.com")),
        tokenField("shpat_…"),
        ConfigField(key: "range", title: "Range", type: .choice(rangeChoices))
    ]

    static var browsable: [WidgetKind] { WidgetKind.allCases.filter { $0.spec.browsable } }
}
