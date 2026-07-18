import Foundation

struct ItemLookupFailure: Error, Sendable, Equatable {
    let url: URL
    let domain: String
    let code: Int
    let message: String
}

struct VolumeTarget: Sendable, Equatable {
    let url: URL
    let canonicalMountPath: String
    let volumeIsLocal: Bool?
    let volumeUUIDString: String?
    let volumeMountFromLocation: String?

    init(
        url: URL,
        canonicalMountPath: String,
        volumeIsLocal: Bool?,
        volumeUUIDString: String? = nil,
        volumeMountFromLocation: String? = nil
    ) {
        self.url = url
        self.canonicalMountPath = canonicalMountPath
        self.volumeIsLocal = volumeIsLocal
        self.volumeUUIDString = volumeUUIDString
        self.volumeMountFromLocation = volumeMountFromLocation
    }
}

enum ItemClassification: Sendable, Equatable {
    case file(URL)
    case volume(VolumeTarget)
    case lookupFailed(ItemLookupFailure)
}

enum VolumeMountState: Sendable, Equatable {
    case mounted
    case alreadyUnmounted
    case lookupFailed(ItemLookupFailure)
}

struct VolumeUnmountFailure: Error, Sendable, Equatable {
    let volumeURL: URL
    let domain: String
    let code: Int
    let message: String
    let dissentingProcessIdentifier: Int32?
}

enum VolumeUnmountResult: Sendable, Equatable {
    case success(URL)
    case failure(VolumeUnmountFailure)
    case lookupFailed(ItemLookupFailure)
}

final class TrashService: Sendable {
    struct VolumeResourceValues: Sendable {
        let isVolume: Bool?
        let volumeIsLocal: Bool?
        let volumeURL: URL?
        let volumeUUIDString: String?
        let volumeMountFromLocation: String?

        init(
            isVolume: Bool?,
            volumeIsLocal: Bool?,
            volumeURL: URL?,
            volumeUUIDString: String? = nil,
            volumeMountFromLocation: String? = nil
        ) {
            self.isVolume = isVolume
            self.volumeIsLocal = volumeIsLocal
            self.volumeURL = volumeURL
            self.volumeUUIDString = volumeUUIDString
            self.volumeMountFromLocation = volumeMountFromLocation
        }
    }

    struct Dependencies: Sendable {
        let volumeResourceValues: @Sendable (URL) throws -> VolumeResourceValues
        let currentVolumeResourceValues: @Sendable (URL) throws -> VolumeResourceValues
        let unmountVolume: @Sendable (URL, FileManager.UnmountOptions) async throws -> Void
        let waitBeforeRetry: @Sendable () async throws -> Void

        static let live = Dependencies(
            volumeResourceValues: { url in
                try TrashService.readVolumeResourceValues(from: url)
            },
            currentVolumeResourceValues: { url in
                try TrashService.readVolumeResourceValues(from: url)
            },
            unmountVolume: { url, options in
                try await FileManager.default.unmountVolume(at: url, options: options)
            },
            waitBeforeRetry: {
                try await Task.sleep(for: .milliseconds(250))
            }
        )
    }

    private static let maximumUnmountAttempts = 3

    private let dependencies: Dependencies

    init(dependencies: Dependencies = .live) {
        self.dependencies = dependencies
    }

    func moveToTrash(url: URL) -> Bool {
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            return true
        } catch {
            return false
        }
    }

    func eject(volume: VolumeTarget) async -> VolumeUnmountResult {
        let options = Self.unmountOptions(volumeIsLocal: volume.volumeIsLocal)

        for attempt in 1...Self.maximumUnmountAttempts {
            guard !Task.isCancelled else {
                return .failure(
                    Self.unmountFailure(volumeURL: volume.url, error: CancellationError())
                )
            }

            switch mountState(of: volume) {
            case .mounted:
                break
            case .alreadyUnmounted:
                return .success(volume.url)
            case .lookupFailed(let failure):
                guard attempt < Self.maximumUnmountAttempts else {
                    return .lookupFailed(failure)
                }
                do {
                    try await dependencies.waitBeforeRetry()
                } catch {
                    return .failure(Self.unmountFailure(volumeURL: volume.url, error: error))
                }
                continue
            }

            do {
                try await dependencies.unmountVolume(volume.url, options)
                return .success(volume.url)
            } catch {
                let failure = Self.unmountFailure(volumeURL: volume.url, error: error)
                guard Self.isBusyUnmountFailure(failure),
                      attempt < Self.maximumUnmountAttempts else {
                    return .failure(failure)
                }

                do {
                    try await dependencies.waitBeforeRetry()
                } catch {
                    return .failure(Self.unmountFailure(volumeURL: volume.url, error: error))
                }
            }
        }

        preconditionFailure("The unmount retry loop must return a result.")
    }

    func classifyItem(at url: URL) -> ItemClassification {
        do {
            let values = try dependencies.volumeResourceValues(url)
            guard let isVolume = values.isVolume else {
                return .lookupFailed(Self.missingVolumeFlagFailure(url: url))
            }

            guard isVolume else {
                return .file(url)
            }

            let volumeURL = values.volumeURL ?? url
            return .volume(VolumeTarget(
                url: volumeURL,
                canonicalMountPath: Self.canonicalMountPath(for: volumeURL),
                volumeIsLocal: values.volumeIsLocal,
                volumeUUIDString: values.volumeUUIDString,
                volumeMountFromLocation: values.volumeMountFromLocation
            ))
        } catch {
            return .lookupFailed(Self.itemLookupFailure(url: url, error: error))
        }
    }

    func mountState(of volume: VolumeTarget) -> VolumeMountState {
        let currentURL = URL(
            fileURLWithPath: volume.canonicalMountPath,
            isDirectory: true
        )
        do {
            let values = try dependencies.currentVolumeResourceValues(currentURL)
            guard let isVolume = values.isVolume else {
                return .lookupFailed(Self.missingVolumeFlagFailure(url: volume.url))
            }
            guard isVolume else {
                return .alreadyUnmounted
            }
            guard volume.volumeUUIDString != nil || volume.volumeMountFromLocation != nil else {
                return .lookupFailed(Self.missingVolumeIdentityFailure(url: volume.url))
            }
            guard Self.hasSameIdentity(volume, currentValues: values) else {
                return .lookupFailed(Self.replacedVolumeFailure(url: volume.url))
            }
            return .mounted
        } catch {
            let failure = Self.itemLookupFailure(url: volume.url, error: error)
            if Self.isMissingItemFailure(failure) {
                return .alreadyUnmounted
            }
            return .lookupFailed(failure)
        }
    }

    func isVolumeRoot(url: URL) -> Bool {
        guard case .volume = classifyItem(at: url) else {
            return false
        }
        return true
    }

    static func unmountOptions(volumeIsLocal: Bool?) -> FileManager.UnmountOptions {
        var options: FileManager.UnmountOptions = [.withoutUI]
        if volumeIsLocal == true {
            options.insert(.allPartitionsAndEjectDisk)
        }
        return options
    }

    static func unmountFailure(volumeURL: URL, error: any Error) -> VolumeUnmountFailure {
        let nsError = error as NSError
        let dissentingProcessIdentifier = (
            nsError.userInfo[NSFileManagerUnmountDissentingProcessIdentifierErrorKey] as? NSNumber
        )?.int32Value

        return VolumeUnmountFailure(
            volumeURL: volumeURL,
            domain: nsError.domain,
            code: nsError.code,
            message: nsError.localizedDescription,
            dissentingProcessIdentifier: dissentingProcessIdentifier
        )
    }

    static func isBusyUnmountFailure(_ failure: VolumeUnmountFailure) -> Bool {
        failure.domain == NSCocoaErrorDomain
            && failure.code == CocoaError.Code.fileManagerUnmountBusy.rawValue
    }

    private static func canonicalMountPath(for url: URL) -> String {
        url.standardizedFileURL.path
    }

    private static func readVolumeResourceValues(from url: URL) throws -> VolumeResourceValues {
        let values = try url.resourceValues(forKeys: [
            .isVolumeKey,
            .volumeIsLocalKey,
            .volumeURLKey,
            .volumeUUIDStringKey,
            .volumeMountFromLocationKey,
        ])
        return VolumeResourceValues(
            isVolume: values.isVolume,
            volumeIsLocal: values.volumeIsLocal,
            volumeURL: values.volume,
            volumeUUIDString: values.volumeUUIDString,
            volumeMountFromLocation: values.volumeMountFromLocation
        )
    }

    private static func hasSameIdentity(
        _ volume: VolumeTarget,
        currentValues: VolumeResourceValues
    ) -> Bool {
        if let expectedUUID = volume.volumeUUIDString,
           currentValues.volumeUUIDString != expectedUUID {
            return false
        }
        if let expectedLocation = volume.volumeMountFromLocation,
           currentValues.volumeMountFromLocation != expectedLocation {
            return false
        }
        return true
    }

    private static func itemLookupFailure(url: URL, error: any Error) -> ItemLookupFailure {
        let nsError = error as NSError
        return ItemLookupFailure(
            url: url,
            domain: nsError.domain,
            code: nsError.code,
            message: nsError.localizedDescription
        )
    }

    private static func missingVolumeFlagFailure(url: URL) -> ItemLookupFailure {
        ItemLookupFailure(
            url: url,
            domain: NSCocoaErrorDomain,
            code: CocoaError.Code.fileReadUnknown.rawValue,
            message: "項目がボリュームかどうか確認できませんでした。"
        )
    }

    private static func replacedVolumeFailure(url: URL) -> ItemLookupFailure {
        ItemLookupFailure(
            url: url,
            domain: NSCocoaErrorDomain,
            code: CocoaError.Code.fileReadUnknown.rawValue,
            message: "同じ場所に別のボリュームがマウントされています。安全のため処理を中止しました。"
        )
    }

    private static func missingVolumeIdentityFailure(url: URL) -> ItemLookupFailure {
        ItemLookupFailure(
            url: url,
            domain: NSCocoaErrorDomain,
            code: CocoaError.Code.fileReadUnknown.rawValue,
            message: "ボリュームの識別情報を確認できませんでした。安全のため処理を中止しました。"
        )
    }

    private static func isMissingItemFailure(_ failure: ItemLookupFailure) -> Bool {
        (failure.domain == NSCocoaErrorDomain
            && failure.code == CocoaError.Code.fileReadNoSuchFile.rawValue)
            || (failure.domain == NSPOSIXErrorDomain && failure.code == Int(ENOENT))
    }
}
