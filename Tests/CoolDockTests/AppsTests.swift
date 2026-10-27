import Foundation
import Testing
import UniformTypeIdentifiers
@testable import CoolDock

/// Apps family: Chromium profiles and launch arguments, the Dock's recent-documents lists, the folder window's
/// sort / filter / search / breadcrumb model, Dock badge labels and the menu-title matcher.
@Suite struct ChromiumProfileTests {
    static func profiles(_ fixture: String) throws -> [AppsChromium.Profile] {
        AppsChromium.profiles(localState: try Fixture.data("chromium/\(fixture)"))
    }

    @Test func chromeProfilesFollowProfilesOrder() throws {
        let list = try Self.profiles("local-state-chrome.json")
        #expect(list.map(\.directory) == ["Default", "Profile 3", "Profile 1"])
        #expect(list.map(\.name) == ["Personal", "Side Project", "Work"])
    }

    @Test func skipsGuestSystemEphemeralAndHiddenProfiles() throws {
        let chrome = try Self.profiles("local-state-chrome.json").map(\.directory)
        #expect(!chrome.contains("Guest Profile") && !chrome.contains("System Profile"))
        let edge = try Self.profiles("local-state-edge.json").map(\.directory)
        #expect(!edge.contains("Profile 4"))  // is_ephemeral
        #expect(!edge.contains("Profile 6"))  // is_omitted_from_profile_list
    }

    @Test func withoutOrderDefaultComesFirstThenNumericFolderOrder() throws {
        let list = try Self.profiles("local-state-edge.json")
        #expect(list.map(\.directory) == ["Default", "Profile 5", "Profile 9", "Profile 10"])
    }

    @Test func nameFallsBackToShortcutNameThenFolder() throws {
        let byDir = Dictionary(uniqueKeysWithValues: try Self.profiles("local-state-edge.json").map { ($0.directory, $0.name) })
        #expect(byDir["Profile 9"] == "School")      // blank "name"
        #expect(byDir["Profile 5"] == "Profile 5")   // no name at all
        #expect(byDir["Default"] == "Profile 1")     // Edge calls its first profile "Profile 1"
    }

    @Test func singleProfileAndMalformedInput() throws {
        #expect(try Self.profiles("local-state-single.json").map(\.name) == ["Person 1"])
        #expect(AppsChromium.profiles(localState: Data("{ not json".utf8)).isEmpty)
        #expect(AppsChromium.profiles(localState: Data(#"{"profile": {"info_cache": []}}"#.utf8)).isEmpty)
        #expect(AppsChromium.profiles(localState: Data("{}".utf8)).isEmpty)
    }

    @Test func readsLocalStateFromTheChannelFolderAndRereadsWhenItChanges() throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("nicedock-chromium-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: support) }
        let canary = try #require(AppsChromium.spec("com.google.Chrome.canary"))
        let file = canary.localState(in: support)
        #expect(file.path.hasSuffix("/Google/Chrome Canary/Local State"))
        #expect(canary.profiles(in: support).isEmpty)  // not installed
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Fixture.data("chromium/local-state-single.json").write(to: file)
        #expect(canary.profiles(in: support).map(\.name) == ["Person 1"])
        try Fixture.data("chromium/local-state-chrome.json").write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: file.path)
        #expect(canary.profiles(in: support).count == 3)
    }
}

@Suite struct ChromiumLaunchTests {
    @Test func knowsEveryChannel() throws {
        let ids = ["com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
                   "org.chromium.Chromium", "com.brave.Browser", "com.brave.Browser.beta", "com.brave.Browser.nightly",
                   "com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev", "com.microsoft.edgemac.Canary",
                   "com.vivaldi.Vivaldi"]
        for id in ids { #expect(AppsChromium.spec(id) != nil, "\(id)") }
        #expect(AppsChromium.spec("com.microsoft.EdgeMac.beta")?.dataDir == "Microsoft Edge Beta")  // case-insensitive
        #expect(AppsChromium.spec("com.apple.Safari") == nil)
        #expect(AppsChromium.spec(nil) == nil)
    }

    @Test func dataFolders() {
        #expect(AppsChromium.spec("com.google.Chrome")?.dataDir == "Google/Chrome")
        #expect(AppsChromium.spec("com.google.Chrome.beta")?.dataDir == "Google/Chrome Beta")
        #expect(AppsChromium.spec("com.brave.Browser")?.dataDir == "BraveSoftware/Brave-Browser")
        #expect(AppsChromium.spec("com.brave.Browser.nightly")?.dataDir == "BraveSoftware/Brave-Browser-Nightly")
        #expect(AppsChromium.spec("com.microsoft.edgemac")?.dataDir == "Microsoft Edge")
        #expect(AppsChromium.spec("com.vivaldi.Vivaldi")?.dataDir == "Vivaldi")
        #expect(AppsChromium.spec("org.chromium.Chromium")?.dataDir == "Chromium")
    }

    @Test func newWindowAndProfileArguments() throws {
        let chrome = try #require(AppsChromium.spec("com.google.Chrome"))
        let app = "/Applications/Google Chrome.app"
        #expect(chrome.openArguments(appPath: app, .newWindow) == ["-na", app, "--args", "--new-window"])
        #expect(chrome.openArguments(appPath: app, .profile("Profile 3")) ==
                ["-na", app, "--args", "--profile-directory=Profile 3", "--new-window"])
        #expect(chrome.openArguments(appPath: app, .profile("Default")).contains("--profile-directory=Default"))
    }

    @Test func privateWindowSwitchAndTitlePerBrowser() throws {
        let cases: [(String, String, String)] = [
            ("com.google.Chrome", "--incognito", "New Incognito Window"),
            ("org.chromium.Chromium", "--incognito", "New Incognito Window"),
            ("com.brave.Browser", "--incognito", "New Private Window"),
            ("com.vivaldi.Vivaldi", "--incognito", "New Private Window"),
            ("com.microsoft.edgemac", "--inprivate", "New InPrivate Window"),
            ("com.microsoft.edgemac.Canary", "--inprivate", "New InPrivate Window")
        ]
        for (id, flag, title) in cases {
            let spec = try #require(AppsChromium.spec(id))
            #expect(spec.openArguments(appPath: "/A.app", .privateWindow) == ["-na", "/A.app", "--args", flag], "\(id)")
            #expect(spec.privateTitle == title, "\(id)")
        }
    }
}

@Suite struct RecentDocumentsTests {
    /// A temp folder with real files, so bookmarks can be created for them.
    static func sandbox() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nicedock-sfl-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func file(_ dir: URL, _ name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        return url
    }

    /// Same shape as the system's `.sfl3`: a keyed archive of `{ items: [{ Bookmark, uuid, visibility, … }], properties }`.
    static func sfl(_ urls: [URL]) throws -> Data {
        let items: [NSDictionary] = try urls.map { url in
            ["Bookmark": try url.bookmarkData(), "uuid": UUID().uuidString, "visibility": 0, "CustomItemProperties": NSDictionary()]
        }
        let root: NSDictionary = ["items": items, "properties": ["com.apple.LSSharedFileList.MaxAmount": 10] as NSDictionary]
        return try NSKeyedArchiver.archivedData(withRootObject: root, requiringSecureCoding: false)
    }

    @Test func decodesBookmarksInOrder() throws {
        let dir = try Self.sandbox()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try Self.file(dir, "Quarterly Plan.txt"), b = try Self.file(dir, "Notes.rtf"), c = try Self.file(dir, "Café.md")
        let entries = AppsRecentDocs.decode(try Self.sfl([a, b, c]))
        #expect(entries.map(\.url.lastPathComponent) == ["Quarterly Plan.txt", "Notes.rtf", "Café.md"])
        #expect(entries.map(\.url.standardizedFileURL.path) == [a, b, c].map(\.standardizedFileURL.path)
                || entries.map { $0.url.resolvingSymlinksInPath().path } == [a, b, c].map { $0.resolvingSymlinksInPath().path })
    }

    @Test func findsTheListFileByLowercasedBundleIDAndPrefersSfl3() throws {
        let dir = try Self.sandbox()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(AppsRecentDocs.file(bundleID: "com.Example.Editor", in: dir) == nil)
        try Data().write(to: dir.appendingPathComponent("com.example.editor.sfl2"))
        #expect(AppsRecentDocs.file(bundleID: "com.Example.Editor", in: dir)?.lastPathComponent == "com.example.editor.sfl2")
        try Data().write(to: dir.appendingPathComponent("com.example.editor.sfl3"))
        #expect(AppsRecentDocs.file(bundleID: "com.Example.Editor", in: dir)?.lastPathComponent == "com.example.editor.sfl3")
    }

    @Test func entriesSkipMissingFilesDuplicatesAndRespectTheLimit() throws {
        let dir = try Self.sandbox()
        defer { try? FileManager.default.removeItem(at: dir) }
        let docs = try (1...5).map { try Self.file(dir, "Doc \($0).txt") }
        let lists = dir.appendingPathComponent("lists", isDirectory: true)
        try FileManager.default.createDirectory(at: lists, withIntermediateDirectories: true)
        try Self.sfl([docs[0], docs[1], docs[0], docs[2], docs[3], docs[4]]).write(to: lists.appendingPathComponent("com.example.writer.sfl3"))
        try FileManager.default.removeItem(at: docs[1])
        let entries = AppsRecentDocs.entries(bundleID: "com.example.writer", limit: 3, in: lists)
        #expect(entries.map(\.url.lastPathComponent) == ["Doc 1.txt", "Doc 3.txt", "Doc 4.txt"])
        #expect(AppsRecentDocs.entries(bundleID: "com.example.none", in: lists).isEmpty)
    }

    @Test func fallsBackToTheRawObjectTableForUnknownClasses() throws {
        let dir = try Self.sandbox()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try Self.file(dir, "First.txt"), b = try Self.file(dir, "Second.txt")
        let items = try [a, b].map { SFLTestItem(bookmark: try $0.bookmarkData()) }
        let data = try NSKeyedArchiver.archivedData(withRootObject: ["items": items] as NSDictionary, requiringSecureCoding: false)
        #expect(AppsRecentDocs.decode(data).map(\.url.lastPathComponent) == ["First.txt", "Second.txt"])
    }

    @Test func garbageDecodesToNothing() {
        #expect(AppsRecentDocs.decode(Data("not an archive".utf8)).isEmpty)
        #expect(AppsRecentDocs.decode(Data()).isEmpty)
    }
}

/// Stands in for a private list-item class the secure unarchiver doesn't know.
@objc(SFLTestItem) final class SFLTestItem: NSObject, NSCoding {
    let bookmark: Data
    init(bookmark: Data) { self.bookmark = bookmark }
    init?(coder: NSCoder) {
        guard let data = coder.decodeObject(forKey: "Bookmark") as? Data else { return nil }
        bookmark = data
    }
    func encode(with coder: NSCoder) { coder.encode(bookmark, forKey: "Bookmark") }
}

@Suite struct FolderBrowserTests {
    static let base = Date(timeIntervalSince1970: 1_780_000_000)

    static func item(_ name: String, folder: Bool = false, size: Int64? = nil, added: Double = 0, modified: Double = 0, kind: String = "") -> AppsFileItem {
        let url = URL(fileURLWithPath: "/tmp/Root/" + name)
        let type = folder ? "public.folder" : (UTType(filenameExtension: url.pathExtension)?.identifier ?? "")
        return AppsFileItem(url: url, name: name, date: base.addingTimeInterval(added * 86_400), size: folder ? nil : size, isFolder: folder,
                            modified: base.addingTimeInterval(modified * 86_400), type: type, kind: kind.isEmpty ? (folder ? "Folder" : url.pathExtension) : kind)
    }

    static let items: [AppsFileItem] = [
        item("Projects", folder: true, added: 5, modified: 1),
        item("Annual Report 2026.pdf", size: 1_400_000, added: 1, modified: 3, kind: "PDF document"),
        item("Report Draft.docx", size: 90_000, added: 2, modified: 2, kind: "Word document"),
        item("Résumé.pdf", size: 50_000, added: 3, modified: 5, kind: "PDF document"),
        item("Screenshot.png", size: 700_000, added: 4, modified: 4, kind: "PNG image"),
        item("Trip.mov", size: 300_000_000, added: 0, modified: 0, kind: "QuickTime movie"),
        item("Podcast.mp3", size: 50_000_000, added: 6, modified: 6, kind: "MP3 audio"),
        item("Assets.zip", size: 25_000_000, added: 7, modified: 7, kind: "ZIP archive"),
        item("Calculator.app", size: 4_000_000, added: 8, modified: 8, kind: "Application"),
        item("File 10.txt", size: 10, added: 9, modified: 9, kind: "Plain text"),
        item("File 2.txt", size: 20, added: 10, modified: 10, kind: "Plain text"),
        item("data.xyz123", size: 1, added: 11, modified: 11, kind: "Document")
    ]

    static func names(_ list: [AppsFileItem]) -> [String] { list.map(\.name) }

    static func apply(query: String = "", filter: AppsFolderFilter = .all, sort: AppsFolderSort = .name, ascending: Bool = true) -> [String] {
        names(AppsFolderQuery.apply(items, query: query, filter: filter, sort: sort, ascending: ascending))
    }

    @Test func categories() {
        func cat(_ name: String) -> AppsFolderFilter { AppsFolderQuery.category(Self.items.first { $0.name == name }!) }
        #expect(cat("Projects") == .folders)
        #expect(cat("Annual Report 2026.pdf") == .documents)
        #expect(cat("File 2.txt") == .documents)
        #expect(cat("Screenshot.png") == .images)
        #expect(cat("Trip.mov") == .media)
        #expect(cat("Podcast.mp3") == .media)
        #expect(cat("Assets.zip") == .archives)
        #expect(cat("Calculator.app") == .apps)
        #expect(cat("data.xyz123") == .all)
    }

    @Test func filters() {
        #expect(Self.apply(filter: .folders) == ["Projects"])
        #expect(Self.apply(filter: .images) == ["Screenshot.png"])
        #expect(Self.apply(filter: .media) == ["Podcast.mp3", "Trip.mov"])
        #expect(Self.apply(filter: .apps) == ["Calculator.app"])
        #expect(Self.apply(filter: .archives) == ["Assets.zip"])
        #expect(Self.apply(filter: .documents).count == 5)  // 2 pdf, docx, 2 txt
        #expect(Self.apply().count == Self.items.count)
    }

    @Test func searchIgnoresCaseAndDiacriticsAndNeedsEveryWord() {
        #expect(Self.apply(query: "REPORT") == ["Annual Report 2026.pdf", "Report Draft.docx"])
        #expect(Self.apply(query: "resume") == ["Résumé.pdf"])
        #expect(Self.apply(query: "report 2026") == ["Annual Report 2026.pdf"])
        #expect(Self.apply(query: "  ") == Self.apply())
        #expect(Self.apply(query: "report", filter: .documents, sort: .modified, ascending: false) == ["Annual Report 2026.pdf", "Report Draft.docx"])
        #expect(Self.apply(query: "nothing here").isEmpty)
    }

    @Test func sortByNameIsNumericAware() {
        let names = Self.apply(filter: .documents)
        #expect(names.firstIndex(of: "File 2.txt")! < names.firstIndex(of: "File 10.txt")!)
        #expect(Self.apply(sort: .name, ascending: false).first == "Trip.mov")
    }

    @Test func sortByDates() {
        #expect(Self.apply(sort: .added, ascending: false).prefix(3) == ["data.xyz123", "File 2.txt", "File 10.txt"])
        #expect(Self.apply(sort: .added, ascending: true).first == "Trip.mov")
        #expect(Self.apply(sort: .modified, ascending: true).prefix(2) == ["Trip.mov", "Projects"])
    }

    @Test func sortBySizePutsFoldersAfterFilesWhenBiggestFirst() {
        let desc = Self.apply(sort: .size, ascending: false)
        #expect(desc.first == "Trip.mov")
        #expect(desc.last == "Projects")
        let asc = Self.apply(sort: .size, ascending: true)
        #expect(asc.first == "Projects")
        #expect(asc[1] == "data.xyz123")
    }

    @Test func sortByKindKeepsFoldersFirstThenGroupsKinds() {
        let list = Self.apply(sort: .kind, ascending: true)
        #expect(list.first == "Projects")
        let pdfs = list.indices.filter { list[$0].hasSuffix(".pdf") }
        #expect(pdfs == [pdfs[0], pdfs[0] + 1])  // the two PDF documents sit together
        #expect(Self.apply(sort: .kind, ascending: false).last == "Projects")
    }

    @Test func defaultDirections() {
        #expect(AppsFolderSort.name.defaultAscending && AppsFolderSort.kind.defaultAscending)
        #expect(!AppsFolderSort.added.defaultAscending && !AppsFolderSort.modified.defaultAscending && !AppsFolderSort.size.defaultAscending)
    }

    @Test func breadcrumbsDrillInAndBackUp() {
        var trail = AppsFolderTrail(root: "/tmp/Root/")
        #expect(trail.root == "/tmp/Root" && trail.depth == 0 && !trail.canGoUp)
        #expect(trail.crumbs(rootTitle: "Root").map(\.title) == ["Root"])
        do { let entered = trail.enter("/tmp/Root/Projects"); #expect(entered) }
        do { let entered = trail.enter("/tmp/Root/Projects/2026/Mockups"); #expect(entered) }  // any depth below the root
        #expect(trail.depth == 3)
        #expect(trail.crumbs(rootTitle: "Studio").map(\.title) == ["Studio", "Projects", "2026", "Mockups"])
        #expect(trail.crumbs(rootTitle: "Studio").map(\.path) == ["/tmp/Root", "/tmp/Root/Projects", "/tmp/Root/Projects/2026", "/tmp/Root/Projects/2026/Mockups"])
        trail.up()
        #expect(trail.path == "/tmp/Root/Projects/2026")
        trail.jump(to: 1)
        #expect(trail.path == "/tmp/Root/Projects")
        trail.jump(to: 7)  // out of range: stays
        #expect(trail.path == "/tmp/Root/Projects")
        trail.jump(to: 0)
        #expect(trail.path == "/tmp/Root" && !trail.canGoUp)
        trail.up()  // can't climb above the root
        #expect(trail.path == "/tmp/Root")
    }

    @Test func breadcrumbsStayInsideTheRoot() {
        var trail = AppsFolderTrail(root: "/tmp/Root")
        do { let entered = trail.enter("/tmp/Other"); #expect(!entered) }
        do { let entered = trail.enter("/tmp/RootBeer"); #expect(!entered) }  // shares the prefix, but isn't inside
        do { let entered = trail.enter("/tmp/Root/../Other"); #expect(!entered) }
        do { let entered = trail.enter("/tmp/Root/A/./B/"); #expect(entered) }
        #expect(trail.path == "/tmp/Root/A/B")
        var top = AppsFolderTrail(root: "/")
        do { let entered = top.enter("/Users"); #expect(entered) }
        #expect(top.crumbs(rootTitle: "Macintosh HD").map(\.path) == ["/", "/Users"])
    }

    @Test func protectedZones() {
        let home = NSHomeDirectory()
        #expect(AppsFS.protectedZone(home + "/Documents/Work/Plans") == home + "/Documents")
        #expect(AppsFS.protectedZone(home + "/Desktop") == home + "/Desktop")
        #expect(AppsFS.protectedZone(home + "/Projects") == nil)
        #expect(AppsFS.protectedZone("/Volumes/Backup/Photos") == "/Volumes/Backup")
        #expect(AppsFolderPreviews.allowed(home + "/Documents/A", root: home + "/Documents") == true)
        #expect(AppsFolderPreviews.allowed(home + "/Desktop", root: home) == false)
    }
}

@Suite struct DockBadgeTests {
    static let enNumber: (Int) -> String = { n in
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US")
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n))!
    }
    static let faNumber: (Int) -> String = { n in
        let f = NumberFormatter()
        f.locale = Locale(identifier: "fa_IR@numbers=arabext")
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n))!
    }
    static let compact: (Double) -> String = { "\(Int($0 / 1000))K" }
    static let persianDigits: (String) -> String = { s in
        String(s.unicodeScalars.map { $0.value >= 48 && $0.value <= 57 ? Character(UnicodeScalar($0.value - 48 + 0x06F0)!) : Character($0) })
    }

    static func en(_ raw: String?) -> String? { AppsBadgeLabel.format(raw, number: enNumber, compact: compact, digits: { $0 }) }

    @Test func noBadge() {
        #expect(Self.en(nil) == nil)
        #expect(Self.en("") == nil)
        #expect(Self.en("   ") == nil)
        #expect(Self.en("0") == nil)
    }

    @Test func countsGetGrouping() {
        #expect(Self.en("3") == "3")
        #expect(Self.en("999") == "999")
        #expect(Self.en("1234") == "1,234")
        #expect(Self.en("1,234") == "1,234")
        #expect(Self.en(" 42 ") == "42")
        #expect(Self.en("9999") == "9,999")
    }

    @Test func bigCountsTurnCompact() {
        #expect(Self.en("10000") == "10K")
        #expect(Self.en("15000") == "15K")
    }

    @Test func textLabelsPassThrough() {
        #expect(Self.en("99+") == "99+")
        #expect(Self.en("!") == "!")
        #expect(Self.en("New") == "New")
        #expect(Self.en("Downloading") == "Download…")
    }

    @Test func persianDigitsBothWays() {
        let fa = { (raw: String) in AppsBadgeLabel.format(raw, number: Self.faNumber, compact: Self.compact, digits: Self.persianDigits) }
        #expect(fa("1234") == "۱٬۲۳۴")
        #expect(fa("99+") == "۹۹+")
        #expect(AppsBadgeLabel.count("۱۲") == 12)
        #expect(AppsBadgeLabel.count("١٬٢٣٤") == 1234)
        #expect(AppsBadgeLabel.count("12a") == nil)
        #expect(AppsBadgeLabel.count(",") == nil)
    }
}

@Suite struct AppMenuMatchingTests {
    @Test func newWindowTitles() {
        for title in ["New Window", "New Finder Window", "Neues Fenster", "Nouvelle fenêtre", "Nueva ventana", "Новое окно",
                      "新建窗口", "新規ウインドウ", "پنجره جدید", "نافذة جديدة", "Yeni Pencere"] {
            #expect(AppsAX.isNewWindow(title), "\(title)")
        }
        for title in ["New Private Window", "New Incognito Window", "New InPrivate Window", "New Tab", "Close Window",
                      "Nouvelle fenêtre privée", "پنجره خصوصی جدید"] {
            #expect(!AppsAX.isNewWindow(title), "\(title)")
        }
    }

    @Test func composeURLs() {
        #expect(AppsKnownApps.composeURL(bundleID: "com.apple.mail", schemes: ["mailto"]).absoluteString == "mailto:")
        #expect(AppsKnownApps.composeURL(bundleID: "com.microsoft.Outlook", schemes: ["mailto", "ms-outlook"]).absoluteString == "mailto:")
        #expect(AppsKnownApps.composeURL(bundleID: "com.readdle.SparkDesktop", schemes: ["readdle-spark", "mailto"]).absoluteString == "readdle-spark://compose")
        #expect(AppsKnownApps.composeURL(bundleID: "com.readdle.SparkDesktop", schemes: ["mailto"]).absoluteString == "mailto:")
    }

    @Test func knownApps() {
        #expect(AppsKnownApps.documents == ["com.apple.iWork.Pages", "com.apple.iWork.Numbers", "com.apple.iWork.Keynote", "com.apple.TextEdit"])
        #expect(AppsKnownApps.mail.contains("com.apple.mail") && AppsKnownApps.mail.contains("com.microsoft.Outlook"))
        #expect(AppsKnownApps.windowShortcuts["notion.id"]?.shift == true)
    }
}
