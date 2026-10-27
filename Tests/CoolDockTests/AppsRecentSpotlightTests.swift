import AppKit
import Testing
import UniformTypeIdentifiers
@testable import CoolDock

/// Open Recent without Full Disk Access: Spotlight's recently used files that open in the app by default.
@Suite struct AppsRecentSpotlightTests {
    @Test func queryCoversEveryTypeAndTheWindow() {
        let q = AppsRecentDocs.query([.pdf, .png], days: 30)
        #expect(q == "kMDItemLastUsedDate >= $time.today(-30) && (kMDItemContentTypeTree == \"com.adobe.pdf\" || kMDItemContentTypeTree == \"public.png\")")
        // Bounded however many types an app declares.
        let many = (0..<40).compactMap { UTType(filenameExtension: "x\($0)") }
        #expect(AppsRecentDocs.query(many).components(separatedBy: "kMDItemContentTypeTree").count - 1 == 24)
    }

    @Test func onlyDocumentsAPersonOpened() {
        let home = "/Users/me"
        #expect(AppsRecentDocs.isUserDocument("/Users/me/Desktop/Report.pdf", home: home))
        #expect(AppsRecentDocs.isUserDocument("/Volumes/Work/plan.key", home: home))
        #expect(!AppsRecentDocs.isUserDocument("/Users/me/Library/Caches/x.png", home: home))
        #expect(!AppsRecentDocs.isUserDocument("/Users/me/.Trash/old.pdf", home: home))
        #expect(!AppsRecentDocs.isUserDocument("/Users/me/Projects/.git/x.txt", home: home))
        #expect(!AppsRecentDocs.isUserDocument("/Applications/Preview.app/Contents/Resources/a.png", home: home))
        #expect(!AppsRecentDocs.isUserDocument("/System/Library/Desktop Pictures/a.heic", home: home))
    }

    @Test func defaultTypesAreOnlyThoseTheAppOpensByDefault() throws {
        let app = try #require(NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview"))
        let types = AppsRecentDocs.defaultTypes(of: app)
        #expect(Set(types.map(\.identifier)).count == types.count)
        for t in types { #expect(NSWorkspace.shared.urlForApplication(toOpen: t)?.standardizedFileURL == app.standardizedFileURL) }
        // An app that declares no documents gets nothing (and no query).
        let calculator = try #require(NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.calculator"))
        #expect(AppsRecentDocs.defaultTypes(of: calculator).isEmpty)
    }
}
