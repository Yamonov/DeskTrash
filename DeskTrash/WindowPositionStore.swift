import Cocoa

final class WindowPositionStore {
    private let defaults: UserDefaults
    private let xKey = "DeskTrashWindowOriginX"
    private let yKey = "DeskTrashWindowOriginY"
    private let fallbackOrigin = NSPoint(x: 500, y: 500)

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func restoreOrigin() -> NSPoint {
        let x = defaults.double(forKey: xKey)
        let y = defaults.double(forKey: yKey)

        guard x != 0, y != 0 else {
            return fallbackOrigin
        }

        return NSPoint(x: x, y: y)
    }

    func save(origin: NSPoint) {
        defaults.set(origin.x, forKey: xKey)
        defaults.set(origin.y, forKey: yKey)
    }
}
