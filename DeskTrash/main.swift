import Cocoa

// 明示的エントリポイント
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate

    // デバッグ中に Dock アイコンを出したいときは有効化
    // app.setActivationPolicy(.regular)

    app.run()
}
