import AudioToolbox
import Foundation

final class SoundPlayer {
    private let dragToTrashSoundID = SoundPlayer.loadSoundID(resource: "Dragtotrash")
    private let emptyTrashSoundID = SoundPlayer.loadSoundID(resource: "Emptytrash")
    private let ejectSoundID = SoundPlayer.loadSoundID(resource: "eject")

    deinit {
        dispose(dragToTrashSoundID)
        dispose(emptyTrashSoundID)
        dispose(ejectSoundID)
    }

    func playDragToTrash() {
        play(dragToTrashSoundID)
    }

    func playEmptyTrash() {
        play(emptyTrashSoundID)
    }

    func playEject() {
        play(ejectSoundID)
    }

    private func play(_ soundID: SystemSoundID?) {
        guard let soundID else { return }
        AudioServicesPlaySystemSound(soundID)
    }

    private func dispose(_ soundID: SystemSoundID?) {
        guard let soundID else { return }
        AudioServicesDisposeSystemSoundID(soundID)
    }

    private static func loadSoundID(resource: String) -> SystemSoundID? {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "caf") else {
            return nil
        }

        var soundID: SystemSoundID = 0
        let status = AudioServicesCreateSystemSoundID(url as CFURL, &soundID)
        guard status == kAudioServicesNoError else {
            return nil
        }
        return soundID
    }
}
