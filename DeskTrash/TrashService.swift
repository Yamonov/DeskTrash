import Cocoa

final class TrashService {
    func moveToTrash(url: URL) {
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    func eject(volumeURL: URL) -> Bool {
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: volumeURL)
            return true
        } catch {
            return false
        }
    }

    func isVolumeRoot(url: URL) -> Bool {
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) ?? []
        return volumes.contains(url.standardized)
    }
}
