import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import CoolDock

/// Procedural wallpapers: deterministic, exact size, every style and weather paints. Only the generation path is
/// tested — the desktop picture is never changed here.
@Suite struct WallpaperTests {
    static func pixels(_ request: WallpaperRequest, _ w: Int, _ h: Int) throws -> (data: Data, image: CGImage) {
        let image = try #require(WallpaperRenderer(request: request, width: w, height: h).render())
        let data = try #require(image.dataProvider?.data as Data?)
        return (data, image)
    }

    @Test func sameRequestSameImage() throws {
        let r = WallpaperRequest(mood: .calm, color: "teal", time: .dusk, season: .autumn, weather: .fog)
        let a = try Self.pixels(r, 120, 75)
        let b = try Self.pixels(r, 120, 75)
        #expect(a.data == b.data)
        #expect(a.image.width == 120 && a.image.height == 75)
        #expect(r.seed == WallpaperRequest(mood: .calm, color: "#139a9a", time: .dusk, season: .autumn, weather: .fog).seed,
                "a colour name and its hex value are the same request")
    }

    @Test func parametersChangeTheImage() throws {
        let base = try Self.pixels(WallpaperRequest(mood: .calm, style: .mountains), 96, 60).data
        for other in [WallpaperRequest(mood: .cozy, style: .mountains), WallpaperRequest(mood: .calm, style: .dunes),
                      WallpaperRequest(mood: .calm, style: .mountains, time: .night), WallpaperRequest(mood: .calm, style: .mountains, variation: 1),
                      WallpaperRequest(mood: .calm, style: .mountains, weather: .snow)] {
            #expect(try Self.pixels(other, 96, 60).data != base, "\(other.canonical)")
        }
    }

    @Test func everyStyleAndWeatherPaints() throws {
        for style in WallpaperStyle.allCases {
            for weather in [nil] + WallpaperWeather.allCases.map(Optional.some) {
                let r = WallpaperRequest(style: style, time: .sunset, weather: weather)
                let (_, image) = try Self.pixels(r, 64, 40)
                #expect(image.width == 64 && image.height == 40, "\(r.canonical)")
            }
        }
        for time in WallpaperTime.allCases {
            for season in WallpaperSeason.allCases {
                #expect(WallpaperRenderer(request: WallpaperRequest(time: time, season: season), width: 48, height: 30).render() != nil)
            }
        }
        for mood in WallpaperMood.allCases {
            #expect(WallpaperRenderer(request: WallpaperRequest(mood: mood, color: "black"), width: 48, height: 30).render() != nil)
        }
    }

    @Test func nightIsDarkerThanNoon() throws {
        func meanLuma(_ r: WallpaperRequest) throws -> Double {
            let (data, image) = try Self.pixels(r, 80, 50)
            let bpr = image.bytesPerRow
            var total = 0.0
            for y in 0..<image.height { for x in 0..<image.width { let o = y * bpr + x * 4; total += Double(data[o]) + Double(data[o + 1]) + Double(data[o + 2]) } }
            return total / Double(image.width * image.height * 3 * 255)
        }
        let noon = try meanLuma(WallpaperRequest(style: .mountains, time: .noon))
        let night = try meanLuma(WallpaperRequest(style: .mountains, time: .midnight))
        #expect(noon > night + 0.25, "noon \(noon) vs midnight \(night)")
    }

    @Test func requestValidation() throws {
        func message(_ args: [String: JSONValue]) -> String? {
            do { _ = try WallpaperRequest(arguments: args); return nil } catch let f as ToolFailure { return f.message } catch { return "\(error)" }
        }
        #expect(message(["mood": "angsty"])?.contains("Valid values: calm, serene") == true)
        #expect(message(["style": "cubism"])?.contains("mountains") == true)
        #expect(message(["time_of_day": "teatime"])?.contains("golden_hour") == true)
        #expect(message(["season": "monsoon"])?.contains("spring, summer, autumn, winter") == true)
        #expect(message(["weather": "hail"])?.contains("partly_cloudy") == true)
        #expect(message(["color": "blurple"])?.contains("#3A7BD5") == true)
        #expect(message(["variation": 10_000])?.contains("between 0 and 9999") == true)
        #expect(message(["size": 4])?.contains("Unknown argument 'size'") == true)
        let r = try WallpaperRequest(arguments: ["mood": "Peaceful", "time_of_day": "golden hour", "season": "fall", "weather": "rainy", "color": "Sky Blue"])
        #expect(r.mood == .calm && r.time == .goldenHour && r.season == .autumn && r.weather == .rain && r.colorHex == "#5AB0F0")
        #expect(r.style == nil)
        #expect(r.resolvedStyle.isScenic, "scenes with time or season get a landscape")
        #expect(try WallpaperRequest(arguments: [:]).resolvedStyle == WallpaperRequest().resolvedStyle)
    }

    @Test func colourNames() {
        #expect(WallpaperColor.hex("teal") == "#139A9A")
        #expect(WallpaperColor.hex("#abc") == "#AABBCC")
        #expect(WallpaperColor.hex("3a7bd5") == "#3A7BD5")
        #expect(WallpaperColor.hex("Hot Pink") == WallpaperColor.hex("magenta"))
        #expect(WallpaperColor.hex("#12345") == nil)
        #expect(WallpaperColor.hex("plaid") == nil)
    }

    @Test func savesUnderTheWallpapersFolder() throws {
        let dir = AssistantFixture.tempDirectory().appendingPathComponent("Wallpapers", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let r = WallpaperRequest(mood: .dreamy, style: .blobs)
        let out = try WallpaperStudio.generate(r, width: 160, height: 100, directory: dir)
        #expect(out.url.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL)
        #expect(out.url.lastPathComponent.hasPrefix("nicedock-dreamy-blobs-"))
        #expect(out.url.lastPathComponent.hasSuffix("-160x100.jpg"))
        let source = try #require(CGImageSourceCreateWithURL(out.url as CFURL, nil))
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(props[kCGImagePropertyPixelWidth] as? Int == 160)
        #expect(props[kCGImagePropertyPixelHeight] as? Int == 100)
        let first = try Data(contentsOf: out.url)
        #expect(try WallpaperStudio.generate(r, width: 160, height: 100, directory: dir).url == out.url)
        #expect(try Data(contentsOf: out.url) == first)
        #expect(throws: ToolFailure.self) { try WallpaperStudio.generate(r, width: 0, height: 100, directory: dir) }
    }

    @Test func keepsOnlyRecentWallpapers() throws {
        let dir = AssistantFixture.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        for v in 0..<5 { _ = try WallpaperStudio.generate(WallpaperRequest(style: .gradient, variation: v), width: 32, height: 20, directory: dir, keep: 3) }
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".jpg") }
        #expect(files.count == 3)
    }

    @Test func previewThroughTheRouterUsesTheScreenSize() throws {
        let dir = AssistantFixture.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try AssistantFixture.write(AssistantFixture.state(enabled: true, allowChanges: false), to: dir.appendingPathComponent("state.json"))
        let result = try AssistantFixture.router(dir: dir).call("preview_wallpaper", ["season": "winter", "weather": "snow", "time_of_day": "morning"])
        #expect(result["width"] == 96 && result["height"] == 60)
        #expect(result["path"]?.stringValue?.hasPrefix(dir.appendingPathComponent("Wallpapers").path) == true)
        #expect(result["parameters"]?["season"] == "winter")
        #expect(result["description"]?.stringValue?.contains("winter") == true)
    }

    /// `COOLDOCK_WALLPAPER_SAMPLES=<dir> swift test --filter WallpaperTests/sampleSheet` writes a contact sheet of typical requests.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["COOLDOCK_WALLPAPER_SAMPLES"] != nil))
    func sampleSheet() throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["COOLDOCK_WALLPAPER_SAMPLES"]!)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let samples: [WallpaperRequest] = [
            WallpaperRequest(mood: .calm), WallpaperRequest(mood: .energetic), WallpaperRequest(mood: .dreamy, style: .blobs),
            WallpaperRequest(time: .sunset, season: .summer), WallpaperRequest(mood: .cozy, time: .evening, season: .autumn),
            WallpaperRequest(time: .night, weather: .clear), WallpaperRequest(season: .winter, weather: .snow),
            WallpaperRequest(mood: .melancholy, weather: .rain), WallpaperRequest(time: .dawn, weather: .fog),
            WallpaperRequest(style: .aurora, color: "purple"), WallpaperRequest(mood: .dramatic, weather: .storm),
            WallpaperRequest(style: .waves, color: "teal"), WallpaperRequest(style: .dunes, time: .goldenHour),
            WallpaperRequest(mood: .romantic, style: .bokeh), WallpaperRequest(style: .minimal, color: "#FF7F6B", time: .sunset),
            WallpaperRequest(mood: .focused, style: .gradient)
        ]
        let cw = 480, ch = 300, cols = 4
        let rows = (samples.count + cols - 1) / cols
        let sheet = try #require(WallpaperRenderer.context(cw * cols, ch * rows))
        for (i, r) in samples.enumerated() {
            let image = try #require(WallpaperRenderer(request: r, width: cw, height: ch).render())
            let x = (i % cols) * cw, y = (rows - 1 - i / cols) * ch
            sheet.draw(image, in: CGRect(x: x, y: y, width: cw, height: ch))
            if i < 4 { _ = try WallpaperStudio.generate(r, width: 1512, height: 982, directory: dir, keep: 100) }
        }
        let out = try #require(sheet.makeImage())
        let url = dir.appendingPathComponent("sheet.png") as CFURL
        let dest = try #require(CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, out, nil)
        #expect(CGImageDestinationFinalize(dest))
        print(samples.enumerated().map { "\($0) \($1.summary)" }.joined(separator: "\n"))
    }
}
