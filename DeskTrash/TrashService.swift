import Cocoa

final class TrashService: Sendable {
    func moveToTrash(url: URL) -> Bool {
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            return true
        } catch {
            return false
        }
    }

    func eject(volumeURL: URL) -> Bool {
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: volumeURL)
            return true
        } catch {
            return false
        }
    }

    func mountedVolumeRoots() -> Set<URL> {
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) ?? []
        return Set(volumes.map(\.standardized))
    }

    func isVolumeRoot(url: URL) -> Bool {
        isVolumeRoot(url: url, mountedVolumeRoots: mountedVolumeRoots())
    }

    func isVolumeRoot(url: URL, mountedVolumeRoots: Set<URL>) -> Bool {
        mountedVolumeRoots.contains(url.standardized)
    }
}
