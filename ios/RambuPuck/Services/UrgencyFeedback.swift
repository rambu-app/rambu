import AudioToolbox
import UIKit

@MainActor
protocol UrgencyFeedbackProviding: AnyObject {
    func presentUrgentFeedback()
}

@MainActor
final class UrgencyFeedback: UrgencyFeedbackProviding {
    private var soundID: SystemSoundID?

    deinit {
        if let soundID {
            AudioServicesDisposeSystemSoundID(soundID)
        }
    }

    func presentUrgentFeedback() {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.error)

        guard let soundID = urgentSoundID() else { return }
        AudioServicesPlaySystemSound(soundID)
    }

    private func urgentSoundID() -> SystemSoundID? {
        if let soundID { return soundID }
        guard let url = Bundle.main.url(forResource: "rambu-urgent", withExtension: "caf") else {
            return nil
        }
        var created: SystemSoundID = 0
        guard AudioServicesCreateSystemSoundID(url as CFURL, &created) == kAudioServicesNoError else {
            return nil
        }
        soundID = created
        return created
    }
}
