import AppKit
import Foundation

struct AppleScriptFailure: Sendable {
    let code: Int
    let message: String
}

enum FinderTrashServiceError: Error {
    case finderUnavailable
    case appleScript(AppleScriptFailure)
}

actor FinderTrashService {
    private lazy var countScript = NSAppleScript(source: """
    tell application "Finder"
        count of items of trash
    end tell
    """)

    private lazy var openTrashScript = NSAppleScript(source: """
    tell application "Finder"
        open trash
        activate
    end tell
    """)

    private lazy var emptyAllScript = NSAppleScript(source: """
    tell application "Finder"
        empty the trash
    end tell
    """)

    func getTrashItemCount() -> Result<Int, FinderTrashServiceError> {
        guard isFinderRunning() else {
            return .failure(.finderUnavailable)
        }

        var error: NSDictionary?
        let result = autoreleasepool { countScript?.executeAndReturnError(&error) }

        if let descriptor = result {
            return .success(Int(descriptor.int32Value))
        }

        return .failure(.appleScript(makeFailure(from: error)))
    }

    func emptyTrash() -> AppleScriptFailure? {
        var error: NSDictionary?
        _ = autoreleasepool { emptyAllScript?.executeAndReturnError(&error) }
        return error.map(makeFailure(from:))
    }

    func openTrash() -> AppleScriptFailure? {
        var error: NSDictionary?
        _ = autoreleasepool { openTrashScript?.executeAndReturnError(&error) }
        return error.map(makeFailure(from:))
    }

    private func isFinderRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").isEmpty
    }

    private func makeFailure(from error: NSDictionary?) -> AppleScriptFailure {
        let code = error?[NSAppleScript.errorNumber] as? Int ?? 0
        let message = error?[NSAppleScript.errorMessage] as? String ?? "Unknown AppleScript error"
        return AppleScriptFailure(code: code, message: message)
    }
}
