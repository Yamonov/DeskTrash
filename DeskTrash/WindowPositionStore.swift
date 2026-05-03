import Cocoa

final class WindowPositionStore {
    private let defaults: UserDefaults
    private let xKey = "DeskTrashWindowOriginX"
    private let yKey = "DeskTrashWindowOriginY"
    private let fallbackOrigin = NSPoint(x: 500, y: 500)

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func restoreOrigin(windowSize: NSSize) -> NSPoint {
        guard defaults.object(forKey: xKey) != nil,
              defaults.object(forKey: yKey) != nil else {
            return fallbackOrigin(windowSize: windowSize)
        }

        let origin = NSPoint(
            x: defaults.double(forKey: xKey),
            y: defaults.double(forKey: yKey)
        )
        let frame = NSRect(origin: origin, size: windowSize)

        guard let screen = screen(containing: frame) else {
            return fallbackOrigin(windowSize: windowSize)
        }

        return clampedOrigin(origin, windowSize: windowSize, visibleFrame: screen.visibleFrame)
    }

    func save(origin: NSPoint) {
        defaults.set(origin.x, forKey: xKey)
        defaults.set(origin.y, forKey: yKey)
    }

    private func screen(containing frame: NSRect) -> NSScreen? {
        NSScreen.screens.first { $0.visibleFrame.intersects(frame) }
    }

    private func fallbackOrigin(windowSize: NSSize) -> NSPoint {
        guard let visibleFrame = NSScreen.main?.visibleFrame else {
            return fallbackOrigin
        }

        return clampedOrigin(fallbackOrigin, windowSize: windowSize, visibleFrame: visibleFrame)
    }

    private func clampedOrigin(_ origin: NSPoint, windowSize: NSSize, visibleFrame: NSRect) -> NSPoint {
        let maxX = max(visibleFrame.minX, visibleFrame.maxX - windowSize.width)
        let maxY = max(visibleFrame.minY, visibleFrame.maxY - windowSize.height)

        return NSPoint(
            x: min(max(origin.x, visibleFrame.minX), maxX),
            y: min(max(origin.y, visibleFrame.minY), maxY)
        )
    }
}
