import Cocoa

@MainActor
private enum AppDelegateStorage {
    static let shared = AppDelegate()
}

// 明示的エントリポイント
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.delegate = AppDelegateStorage.shared

    // デバッグ中に Dock アイコンを出したいときは有効化
    // app.setActivationPolicy(.regular)

    app.run()
}
