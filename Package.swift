// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "CoolDock",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CoolDock", targets: ["CoolDock"])
    ],
    targets: [
        .executableTarget(
            name: "CoolDock",
            path: "Sources/CoolDock",
            swiftSettings: [
                .enableUpcomingFeature("BareSlashRegexLiterals"),
                .unsafeFlags(["-enforce-exclusivity=unchecked"], .when(configuration: .release))
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("IOKit"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreWLAN"),
                .linkedFramework("EventKit"),
                .linkedFramework("Contacts"),
                .linkedFramework("CoreLocation"),
                .linkedFramework("Photos"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("Carbon"),
                .linkedFramework("Security"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedFramework("QuickLookThumbnailing")
            ]
        ),
        // Parser tests over real (curl-captured) and documentation-shaped fixtures in Tests/Fixtures.
        .testTarget(
            name: "CoolDockTests",
            dependencies: ["CoolDock"],
            path: "Tests/CoolDockTests"
        )
    ]
)
