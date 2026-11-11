import Foundation
import Testing
@testable import RambuPuck

@MainActor
struct FamilyViewModelTests {
    private func makeFamily(persona: Persona = .sinta) -> (AppState, FamilyViewModel) {
        let state = AppState(persona: persona, onboardingComplete: true, allowsDemoControls: true)
        state.language = .indonesian
        let profile = ProfileViewModel(
            state: state,
            notifier: RambuNotifier(enabled: false),
            narrator: Narrator(enabled: false),
            network: NetworkMonitor(),
            store: nil
        )
        let family = FamilyViewModel(
            state: state,
            relay: LocalFamilyRelay(),
            feedback: LocalDetectionFeedback(),
            liveActivity: CallLiveActivity(enabled: false),
            profile: profile,
            present: profile.present
        )
        return (state, family)
    }

    private func alert(id: UUID = UUID()) -> FamilyAlert {
        FamilyAlert(
            id: id,
            parent: .ratna,
            callerDetail: "Nomor tidak dikenal",
            channel: .cellular,
            startedAt: .now,
            raisedAt: .now,
            level: .danger,
            signals: [.secretCode],
            evidence: [],
            recipients: Person.guardians,
            decision: nil
        )
    }

    @Test("Alert yang dipublikasi langsung terlihat di AppState bersama")
    func publishUsesSharedState() {
        let (state, family) = makeFamily()
        let alert = alert()

        family.publish(alert)

        #expect(state.alerts.first == alert)
    }

    @Test("Keputusan pertama tetap mengunci pengawas lain")
    func firstDecisionStillWins() throws {
        let (state, family) = makeFamily()
        let alert = alert()
        family.publish(alert)

        guard case .accepted(let first) = family.decide(.scam, on: alert.id) else {
            Issue.record("Keputusan pertama seharusnya diterima")
            return
        }
        state.persona = .richard
        let second = family.decide(.safe, on: alert.id)

        #expect(first.by == .sinta)
        #expect(second == .alreadyDecided(first))
        #expect(try #require(state.toast).title == "Sinta sudah menjawab lebih dulu")
    }

    @Test("English families receive personalized English decision feedback")
    func englishDecisionFeedback() throws {
        let (state, family) = makeFamily()
        state.language = .english
        let alert = alert()
        family.publish(alert)
        family.simulateDecision(by: .richard, .scam, on: alert.id)

        _ = family.decide(.safe, on: alert.id)

        let toast = try #require(state.toast)
        #expect(toast.title == "Richard answered first")
        #expect(toast.body == "Their answer: scam. Only one answer is needed.")
    }

    @Test("Alert selesai tidak membuat riwayat sementara")
    func endedRemoteAlertWaitsForAuthoritativeHistory() {
        let (state, family) = makeFamily()
        state.history = []
        var ended = alert()
        ended.callEnded = true

        family.applyRemoteAlerts([ended])

        #expect(state.history.isEmpty)
    }

    @Test("Keputusan Penipuan dari pendamping membuka layar Matikan telepon di HP orang tua")
    func scamDecisionRaisesHangUpAlarmForParent() {
        let (state, family) = makeFamily(persona: .ratna)
        let alert = alert()
        family.publish(alert)

        family.receive(.decided(alertID: alert.id, GuardianDecision(by: .sinta, verdict: .scam, at: .now)))

        #expect(state.hangUpAlarm == HangUpAlarm(id: alert.id, deciderName: "Sinta"))
    }

    @Test("Keputusan Aman, panggilan yang sudah selesai, dan HP pendamping tidak memicu alarm")
    func hangUpAlarmOnlyForLiveScamOnParentPhone() {
        let (parentState, parentFamily) = makeFamily(persona: .ratna)
        let safe = alert()
        parentFamily.publish(safe)
        parentFamily.receive(.decided(alertID: safe.id, GuardianDecision(by: .sinta, verdict: .safe, at: .now)))
        #expect(parentState.hangUpAlarm == nil)

        var ended = alert()
        ended.callEnded = true
        parentFamily.publish(ended)
        parentFamily.receive(.decided(alertID: ended.id, GuardianDecision(by: .sinta, verdict: .scam, at: .now)))
        #expect(parentState.hangUpAlarm == nil)

        let (guardianState, guardianFamily) = makeFamily(persona: .richard)
        let other = alert()
        guardianFamily.publish(other)
        guardianFamily.receive(.decided(alertID: other.id, GuardianDecision(by: .sinta, verdict: .scam, at: .now)))
        #expect(guardianState.hangUpAlarm == nil)
    }

    @Test("Keputusan Penipuan yang baru datang dari server memicu alarm orang tua")
    func newLiveRemoteScamDecisionRaisesParentTakeover() {
        let (state, family) = makeFamily(persona: .ratna)
        var remote = alert()
        remote.decision = GuardianDecision(by: .sinta, verdict: .scam, at: .now)

        family.applyRemoteAlerts([remote])

        #expect(state.hangUpAlarm == HangUpAlarm(id: remote.id, deciderName: "Sinta"))
    }

    @Test("Keputusan Penipuan historis dari server tidak memicu alarm orang tua")
    func newEndedRemoteScamDecisionDoesNotRaiseParentTakeover() {
        let (state, family) = makeFamily(persona: .ratna)
        var remote = alert()
        remote.decision = GuardianDecision(by: .sinta, verdict: .scam, at: .now)
        remote.callEnded = true

        family.applyRemoteAlerts([remote])

        #expect(state.hangUpAlarm == nil)
    }
}
