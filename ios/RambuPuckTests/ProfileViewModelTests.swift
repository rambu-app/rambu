import Foundation
import Testing
@testable import RambuPuck

@MainActor
private final class RecordingUrgencyFeedback: UrgencyFeedbackProviding {
    private(set) var presentationCount = 0

    func presentUrgentFeedback() {
        presentationCount += 1
    }
}

@MainActor
struct ProfileViewModelTests {
    @Test("Review and danger notifications use the urgent sound")
    func urgentRiskLevelsUseCustomSound() {
        let review = Toast(id: "review", title: "Review", body: "Check", level: .review, alertID: nil)
        let danger = Toast(id: "danger", title: "Danger", body: "Stop", level: .danger, alertID: nil)

        #expect(review.isUrgent)
        #expect(danger.isUrgent)
        #expect(review.notificationSoundName == "rambu-urgent.caf")
        #expect(danger.notificationSoundName == "rambu-urgent.caf")
    }

    @Test("Safe notifications retain the default sound")
    func safeRiskLevelUsesDefaultSound() {
        let safe = Toast(id: "safe", title: "Safe", body: "All clear", level: .safe, alertID: nil)

        #expect(!safe.isUrgent)
        #expect(safe.notificationSoundName == nil)
    }

    @Test("An urgent in-app fallback triggers feedback once")
    func urgentFallbackTriggersFeedbackOnce() {
        let state = AppState(onboardingComplete: true, allowsDemoControls: true)
        let feedback = RecordingUrgencyFeedback()
        let profile = makeProfile(state: state, urgencyFeedback: feedback)
        let toast = Toast(id: "danger", title: "Danger", body: "Stop", level: .danger, alertID: nil)

        profile.present(toast)

        #expect(state.toast == toast)
        #expect(feedback.presentationCount == 1)
    }

    @Test("A safe in-app fallback does not trigger urgent feedback")
    func safeFallbackDoesNotTriggerUrgentFeedback() {
        let state = AppState(onboardingComplete: true, allowsDemoControls: true)
        let feedback = RecordingUrgencyFeedback()
        let profile = makeProfile(state: state, urgencyFeedback: feedback)
        let toast = Toast(id: "safe", title: "Safe", body: "All clear", level: .safe, alertID: nil)

        profile.present(toast)

        #expect(state.toast == toast)
        #expect(feedback.presentationCount == 0)
    }

    @Test("Profil menyimpan perubahan ke state dan penyimpanan yang sama")
    func profilePersistsSharedState() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rambu-profile-\(UUID()).json")
        let store = LocalStore(url: url)
        defer { store.clear() }
        let state = AppState(onboardingComplete: true, allowsDemoControls: true)
        let profile = ProfileViewModel(
            state: state,
            notifier: RambuNotifier(enabled: false),
            narrator: Narrator(enabled: false),
            network: NetworkMonitor(),
            store: store
        )

        profile.renameParent("Bu Sri")
        let added = profile.addProtectedParent(code: "715204")

        #expect(state.parent.name == "Bu Sri")
        #expect(added?.name == "Pak Hadi")
        #expect(try #require(store.load()).parent.name == "Bu Sri")
        #expect(try #require(store.load()).extraParents == [added])
    }

    private func makeProfile(
        state: AppState,
        urgencyFeedback: any UrgencyFeedbackProviding
    ) -> ProfileViewModel {
        ProfileViewModel(
            state: state,
            notifier: RambuNotifier(enabled: false),
            narrator: Narrator(enabled: false),
            network: NetworkMonitor(),
            store: nil,
            urgencyFeedback: urgencyFeedback
        )
    }
}
