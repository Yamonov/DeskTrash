import Cocoa
import ImageIO
import OSLog

/// ゴミ箱ドロップ領域とバッジ表示を担当するビュー
@MainActor
final class DropView: NSView {
    private static let volumeLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "org.iwashi.DeskTrash",
        category: "VolumeUnmount"
    )

    private let trashService = TrashService()
    private let finderTrashService = FinderTrashService()
    private let soundPlayer = SoundPlayer()
    private lazy var trashMonitor = TrashMonitor(finderTrashService: finderTrashService) { [weak self] count in
        self?.updateTrashIcon(count: count)
    }
    private lazy var trashOperationCoordinator = TrashOperationCoordinator(
        suspendTrashMonitoring: { [weak self] in
            await self?.trashMonitor.suspendAndWait()
        },
        resumeTrashMonitoring: { [weak self] in
            self?.trashMonitor.resume()
        }
    )
    private lazy var dropOperationHandler = DropOperationHandler(
        trashService: trashService,
        soundPlayer: soundPlayer,
        refreshTrashStatus: { [weak self] in
            await self?.updateTrashStatus()
        },
        operationCoordinator: trashOperationCoordinator,
        reportDropFailures: { [weak self] failedCount, lookupFailures, volumeFailures in
            self?.showDropFailures(
                failedMoveCount: failedCount,
                lookupFailures: lookupFailures,
                volumeUnmountFailures: volumeFailures
            )
        }
    )
    private lazy var trashActionHandler = TrashActionHandler(
        finderTrashService: finderTrashService,
        soundPlayer: soundPlayer,
        windowProvider: { [weak self] in
            self?.window
        },
        logFinderAppleEventError: { [weak self] error in
            self?.logFinderAppleEventError(error)
        },
        operationCoordinator: trashOperationCoordinator,
        refreshTrashStatus: { [weak self] in
            await self?.updateTrashStatus()
        }
    )

    // MARK: - Layers

    /// メインアイコン描画用レイヤー
    let iconLayer = CALayer()
    /// ドラッグ中に暗転させるレイヤー
    let dimLayer = CALayer()
    /// 件数バッジ描画用レイヤー
    let badgeLayer = CATextLayer()

    // MARK: - Assets

    /// 空のゴミ箱アイコン
    private lazy var emptyCGImage: CGImage? = loadCGImage(name: "trashempty2@2x", ext: "png")
    /// 中身のあるゴミ箱アイコン
    private lazy var fullCGImage: CGImage?  = loadCGImage(name: "trashfull2@2x",  ext: "png")

    // MARK: - Init / Deinit

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        // アクセシビリティ対象外（装飾ビューとして扱う）
        self.setAccessibilityElement(false)
        self.setAccessibilityHidden(true)

        wantsLayer = true
        registerForDraggedTypes([.fileURL])
        setupLayers()
        startTrashMonitoring()   // 以後はタイマーで更新
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)

        // アクセシビリティ対象外（装飾ビューとして扱う）
        self.setAccessibilityElement(false)
        self.setAccessibilityHidden(true)

        wantsLayer = true
        registerForDraggedTypes([.fileURL])
        setupLayers()
        startTrashMonitoring()
    }

    // MARK: - Asset Loading

    /// バンドルから CGImage を ImageIO 経由で読み込む（NSImage を経由しない）
    private func loadCGImage(name: String, ext: String) -> CGImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext) else {
            return nil
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// 件数に応じて適切なゴミ箱アイコンを返し、同時にバッジ表示を更新
    private func cgImageForTrashState(_ count: Int) -> CGImage? {
        updateBadge(count: count)
        return (count == 0) ? emptyCGImage : fullCGImage
    }

    // MARK: - Layer Setup

    func setupLayers() {
        guard let baseLayer = self.layer else { return }

        // アイコンレイヤー
        iconLayer.frame = bounds
        iconLayer.contentsGravity = .resizeAspect
        iconLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        if let image = cgImageForTrashState(0) {
            iconLayer.contents = image
        }
        baseLayer.addSublayer(iconLayer)

        // ドラッグ時の暗転レイヤー
        dimLayer.frame = bounds
        dimLayer.backgroundColor = NSColor.black.withAlphaComponent(0.2).cgColor
        dimLayer.opacity = 0.0
        dimLayer.cornerRadius = 16    // adjust radius as needed
        dimLayer.masksToBounds = true
        baseLayer.addSublayer(dimLayer)

        // バッジレイヤー
        badgeLayer.fontSize = 18
        badgeLayer.foregroundColor = NSColor.white.cgColor
        badgeLayer.backgroundColor = NSColor.systemRed.withAlphaComponent(0.7).cgColor
        badgeLayer.alignmentMode = .center
        badgeLayer.cornerRadius = 12
        badgeLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        badgeLayer.isHidden = true
        badgeLayer.zPosition = 10
        baseLayer.addSublayer(badgeLayer)
    }

    // MARK: - Drag & Drop Handling

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard dropOperationHandler.canAcceptDrop else {
            return []
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dimLayer.opacity = 1.0
        CATransaction.commit()
        return .move
    }

    override func updateDraggingItemsForDrag(_ sender: NSDraggingInfo?) {
        // ここではプレビューを変更しない。AppKit 任せとする。
    }

    override func wantsPeriodicDraggingUpdates() -> Bool {
        return false
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dimLayer.opacity = 0.0
        CATransaction.commit()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dimLayer.opacity = 0.0
        CATransaction.commit()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dimLayer.opacity = 0.0
        return dropOperationHandler.performDrop(from: sender.draggingPasteboard)
    }

    // MARK: - Badge Handling

    func updateBadge(count: Int) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if count > 0 {
            let text = "\(count)"
            badgeLayer.string = text
            let width = max(36, CGFloat(text.count * 11) + 18)
            badgeLayer.frame = CGRect(x: bounds.width - width, y: bounds.height / 2 - 12, width: width, height: 24)
            badgeLayer.isHidden = false
        } else {
            badgeLayer.isHidden = true
        }
        CATransaction.commit()
    }

    /// メインアイコンを現在のゴミ箱状態に合わせて更新
    func updateTrashIcon(count: Int) {
        guard let image = cgImageForTrashState(count) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        iconLayer.contents = image
        CATransaction.commit()
    }

    // MARK: - Finder AppleEvent Helpers

    private func logFinderAppleEventError(_ error: FinderAppleEventFailure) {
        print("Finder AppleEvent error [\(error.code)]: \(error.message)")
    }

    private func showDropFailures(
        failedMoveCount: Int,
        lookupFailures: [ItemLookupFailure],
        volumeUnmountFailures: [VolumeUnmountFailure]
    ) {
        for failure in lookupFailures {
            logItemLookupFailure(failure)
        }
        for failure in volumeUnmountFailures {
            logVolumeUnmountFailure(failure)
        }

        let messageText: String
        let hasVolumeFailures = !lookupFailures.isEmpty || !volumeUnmountFailures.isEmpty
        if failedMoveCount > 0 && hasVolumeFailures {
            messageText = "一部の項目を処理できませんでした"
        } else if !lookupFailures.isEmpty {
            messageText = "項目を確認できませんでした"
        } else if !volumeUnmountFailures.isEmpty {
            messageText = "ボリュームをアンマウントできませんでした"
        } else {
            messageText = "ゴミ箱へ移動できませんでした"
        }

        var details: [String] = []
        if failedMoveCount > 0 {
            let fileMessage = failedMoveCount == 1
                ? "1項目をゴミ箱へ移動できませんでした。"
                : "\(failedMoveCount)項目をゴミ箱へ移動できませんでした。"
            details.append(fileMessage)
        }

        details.append(contentsOf: lookupFailures.map(itemLookupFailureDescription))
        details.append(contentsOf: volumeUnmountFailures.map(volumeUnmountFailureDescription))
        let message = details.joined(separator: "\n\n")

        guard let window else {
            print(message)
            return
        }

        let alert = NSAlert()
        alert.messageText = messageText
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window) { _ in }
    }

    private func volumeUnmountFailureDescription(_ failure: VolumeUnmountFailure) -> String {
        var lines = ["「\(volumeName(for: failure.volumeURL))」", failure.message]
        if let processIdentifier = failure.dissentingProcessIdentifier {
            lines.append("使用中のアプリケーション: \(processDescription(processIdentifier: processIdentifier))")
        }
        return lines.joined(separator: "\n")
    }

    private func itemLookupFailureDescription(_ failure: ItemLookupFailure) -> String {
        [
            "「\(volumeName(for: failure.url))」",
            "項目がファイルかボリュームか確認できませんでした。",
            failure.message,
        ].joined(separator: "\n")
    }

    private func logItemLookupFailure(_ failure: ItemLookupFailure) {
        let name = volumeName(for: failure.url)
        Self.volumeLogger.error(
            "Item lookup failed: domain=\(failure.domain, privacy: .public), code=\(failure.code), item=\(name, privacy: .private), message=\(failure.message, privacy: .private)"
        )
    }

    private func logVolumeUnmountFailure(_ failure: VolumeUnmountFailure) {
        let name = volumeName(for: failure.volumeURL)
        if let processIdentifier = failure.dissentingProcessIdentifier {
            let process = processDescription(processIdentifier: processIdentifier)
            Self.volumeLogger.error(
                "Volume unmount failed: domain=\(failure.domain, privacy: .public), code=\(failure.code), volume=\(name, privacy: .private), message=\(failure.message, privacy: .private), dissentingProcess=\(process, privacy: .private), pid=\(processIdentifier)"
            )
        } else {
            Self.volumeLogger.error(
                "Volume unmount failed: domain=\(failure.domain, privacy: .public), code=\(failure.code), volume=\(name, privacy: .private), message=\(failure.message, privacy: .private)"
            )
        }
    }

    private func volumeName(for url: URL) -> String {
        let name = url.lastPathComponent
        return name.isEmpty ? url.path : name
    }

    private func processDescription(processIdentifier: Int32) -> String {
        if let application = NSRunningApplication(processIdentifier: processIdentifier),
           let applicationName = application.localizedName {
            return "\(applicationName) (PID \(processIdentifier))"
        }
        return "PID \(processIdentifier)"
    }

    // MARK: - Monitoring

    func startTrashMonitoring() {
        trashMonitor.start()
    }

    /// ゴミ箱件数を取得し、変化があれば UI を更新
    func updateTrashStatus() async {
        await trashMonitor.refresh()
    }

    // MARK: - Mouse Handling

    override func mouseDown(with event: NSEvent) {
        if event.type == .leftMouseDown {
            if event.clickCount == 2 {
                trashActionHandler.openTrashFolder()
            } else {
                window?.performDrag(with: event)
            }
        }
    }

    // MARK: - Context Menu

    override func rightMouseDown(with event: NSEvent) {
        let menu = trashActionHandler.makeContextMenu(
            target: self,
            emptyTrashAction: #selector(emptyAllTrash),
            quitAction: #selector(quitApp)
        )
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    // MARK: - Empty Trash Action

    @objc func emptyAllTrash() {
        Task { @MainActor [weak self] in
            await self?.trashActionHandler.emptyTrashAfterConfirmation()
        }
    }

    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}
