import Foundation

/// Reference-scene data for this family (see `ReferenceScene`). Returns nil for kinds it doesn't own.
enum SystemScene {
    @MainActor static func prepare(_ kind: WidgetKind, _ variant: String?) -> [String: String]? {
        switch kind {
        case .cpuRing, .memoryRing, .storageRing, .batteryRing, .cpuGraph, .networkGraph:
            seed()
            return [:]
        default:
            return nil
        }
    }

    /// Values read off the reference frames: CPU 34 %, memory 61 %, 128 GB free of 512 GB,
    /// battery 78 % charging, ↓ 4.2 MB/s ↑ 312 KB/s. Histories trace the frames' curves.
    @MainActor private static func seed() {
        let cpu: [Double] = [0, 1.56, 3.52, 5.91, 8.15, 8.15, 7.16, 9.81, 14.73, 18.57, 20.96, 21.12, 20.18, 22.96, 28.25, 29.9,
                             27.82, 23.63, 18.19, 14.18, 11.69, 11.1, 12.11, 15.57, 20.61, 22.64, 20.91, 18.44, 15.8, 13.28,
                             10.91, 8.87, 7.09, 7.24, 9.55, 11.91, 13.71, 13.46, 10.82, 7.51]
        let down: [Double] = [4.88, 5.41, 6.61, 8.3, 9.97, 11.71, 13.77, 16.3, 18.92, 19.44, 19.05, 20.73, 24.34, 27.3, 29.41,
                              29.51, 27.85, 26.07, 24.37, 22.35, 20.15, 19.81, 21.23, 23.51, 26.47, 28.58, 30.3, 30.55, 29.74,
                              28.34, 26.44, 24.59, 22.69, 20.64, 18.49, 16.51, 14.57, 13.82, 14.55, 15.85]
        let up: [Double] = [0, 0, 0.51, 0.8, 1.03, 1.49, 1.87, 1.99, 2.37, 2.03, 1.98, 2.27, 2.93, 3.48, 3.97, 4, 3.72, 3.46,
                            2.98, 2.54, 2.46, 2.4, 2.47, 2.87, 3.27, 3.47, 3.93, 3.58, 3.44, 2.99, 2.47, 2.37, 1.96, 1.88, 1.48,
                            1.41, 1, 1, 1, 1.04]
        SystemMonitor.shared.seedReference(
            cpu: 0.34, cpuHistory: cpu.map { $0 / 100 },
            memory: 0.609, memoryUsedGB: 9.8,
            down: 4_200_000, up: 312_000,
            downHistory: down.map { $0 * 150_000 }, upHistory: up.map { $0 * 150_000 },
            diskFreeGB: 128, diskTotalGB: 504,
            battery: 0.78, charging: true)
    }
}
