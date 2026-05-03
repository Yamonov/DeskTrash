import AppKit
import Foundation

struct FinderAppleEventFailure: Sendable {
    let code: Int
    let message: String
}

enum FinderTrashServiceError: Error, Sendable {
    case finderUnavailable
    case appleEvent(FinderAppleEventFailure)
}

actor FinderTrashService {
    private let finderBundleIdentifier = "com.apple.finder"
    private let pollingTimeout: TimeInterval = 3
    private let userCommandTimeout: TimeInterval = 30

    func getTrashItemCount() -> Result<Int, FinderTrashServiceError> {
        guard isFinderRunning() else {
            return .failure(.finderUnavailable)
        }

        do {
            return try autoreleasepool {
                let event = makeEvent(eventClass: AEEventClass(kAECoreSuite), eventID: AEEventID(kAECountElements))
                event.setParam(trashObjectSpecifier(), forKeyword: AEKeyword(keyDirectObject))
                event.setParam(NSAppleEventDescriptor(typeCode: OSType(cObject)), forKeyword: AEKeyword(keyAEObjectClass))

                let reply = try send(event, timeout: pollingTimeout)
                if let failure = failure(in: reply) {
                    return .failure(.appleEvent(failure))
                }

                guard let count = reply.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)) else {
                    return .failure(.appleEvent(FinderAppleEventFailure(
                        code: Int(errAEDescNotFound),
                        message: "Finder AppleEvent reply did not include a trash item count"
                    )))
                }
                return .success(Int(count.int32Value))
            }
        } catch {
            return .failure(.appleEvent(makeFailure(from: error)))
        }
    }

    func emptyTrash() -> FinderAppleEventFailure? {
        do {
            return try autoreleasepool {
                let event = makeEvent(eventClass: fourCharCode("fndr"), eventID: fourCharCode("empt"))
                event.setParam(trashObjectSpecifier(), forKeyword: AEKeyword(keyDirectObject))
                let reply = try send(event, timeout: userCommandTimeout)
                return failure(in: reply)
            }
        } catch {
            return makeFailure(from: error)
        }
    }

    func openTrash() -> FinderAppleEventFailure? {
        do {
            return try autoreleasepool {
                let openEvent = makeEvent(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEOpenDocuments))
                openEvent.setParam(trashObjectSpecifier(), forKeyword: AEKeyword(keyDirectObject))
                let openReply = try send(openEvent, timeout: userCommandTimeout)
                if let failure = failure(in: openReply) {
                    return failure
                }

                let activateEvent = makeEvent(eventClass: AEEventClass(kAEMiscStandards), eventID: AEEventID(kAEActivate))
                let activateReply = try send(activateEvent, timeout: userCommandTimeout)
                return failure(in: activateReply)
            }
        } catch {
            return makeFailure(from: error)
        }
    }

    private func isFinderRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").isEmpty
    }

    private func makeEvent(eventClass: AEEventClass, eventID: AEEventID) -> NSAppleEventDescriptor {
        NSAppleEventDescriptor(
            eventClass: eventClass,
            eventID: eventID,
            targetDescriptor: NSAppleEventDescriptor(bundleIdentifier: finderBundleIdentifier),
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
    }

    private func trashObjectSpecifier() -> NSAppleEventDescriptor {
        let descriptor = NSAppleEventDescriptor.record()
        descriptor.setDescriptor(NSAppleEventDescriptor(typeCode: OSType(typeProperty)), forKeyword: AEKeyword(keyAEDesiredClass))
        descriptor.setDescriptor(NSAppleEventDescriptor(enumCode: OSType(formPropertyID)), forKeyword: AEKeyword(keyAEKeyForm))
        descriptor.setDescriptor(NSAppleEventDescriptor(typeCode: fourCharCode("trsh")), forKeyword: AEKeyword(keyAEKeyData))
        descriptor.setDescriptor(NSAppleEventDescriptor.null(), forKeyword: AEKeyword(keyAEContainer))
        return descriptor.coerce(toDescriptorType: DescType(typeObjectSpecifier)) ?? descriptor
    }

    private func send(_ event: NSAppleEventDescriptor, timeout: TimeInterval) throws -> NSAppleEventDescriptor {
        try event.sendEvent(options: [.waitForReply, .canInteract], timeout: timeout)
    }

    private func failure(in reply: NSAppleEventDescriptor) -> FinderAppleEventFailure? {
        guard let errorNumber = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber)) else {
            return nil
        }

        let code = Int(errorNumber.int32Value)
        guard code != 0 else {
            return nil
        }

        let message = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorString))?.stringValue ?? "Finder AppleEvent failed"
        return FinderAppleEventFailure(code: code, message: message)
    }

    private func makeFailure(from error: Error) -> FinderAppleEventFailure {
        let nsError = error as NSError
        return FinderAppleEventFailure(code: nsError.code, message: nsError.localizedDescription)
    }

    private func fourCharCode(_ string: String) -> FourCharCode {
        string.utf8.reduce(FourCharCode(0)) { code, character in
            (code << 8) | FourCharCode(character)
        }
    }
}
