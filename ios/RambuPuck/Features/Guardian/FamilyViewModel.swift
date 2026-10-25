import Foundation
import Observation

/// Mengelola peringatan keluarga dan aturan satu keputusan pertama.
@MainActor
@Observable
final class FamilyViewModel {
    @ObservationIgnored let state: AppState
    @ObservationIgnored private let relay: any FamilyRelay
    @ObservationIgnored let feedback: any DetectionFeedback
    @ObservationIgnored private let liveActivity: CallLiveActivity
    @ObservationIgnored private let profile: ProfileViewModel
    @ObservationIgnored private let present: (Toast) -> Void

    @ObservationIgnored var currentActivityState: ((CallSession) -> RambuCallAttributes.ContentState)?
    @ObservationIgnored var onDecision: (() -> Void)?

    init(
        state: AppState,
        relay: any FamilyRelay,
        feedback: any DetectionFeedback,
        liveActivity: CallLiveActivity,
        profile: ProfileViewModel,
        present: @escaping (Toast) -> Void
    ) {
        self.state = state
        self.relay = relay
        self.feedback = feedback
        self.liveActivity = liveActivity
        self.profile = profile
        self.present = present
        relay.onEvent = { [weak self] event in self?.receive(event) }
    }

    func publish(_ alert: FamilyAlert) {
        relay.publish(alert)
    }

    func canDecide(_ alert: FamilyAlert) -> Bool {
        !state.persona.isParent && alert.decision == nil
    }

    @discardableResult
    func decide(_ verdict: Verdict, on alertID: UUID) -> DecisionOutcome {
        guard !state.persona.isParent else { return .unknownAlert }
        let outcome = relay.submit(
            GuardianDecision(by: state.currentPerson, verdict: verdict, at: .now),
            for: alertID
        )
        if case .alreadyDecided(let existing) = outcome, existing.by != state.currentPerson {
            state.toast = Toast(
                id: "late-\(alertID)",
                title: L10n.format(
                    "family.answered_first",
                    fallback: "%@ sudah menjawab lebih dulu",
                    language: state.language,
                    existing.by.name
                ),
                body: L10n.format(
                    "family.answer_summary",
                    fallback: "Jawabannya: %@. Cukup satu jawaban.",
                    language: state.language,
                    L10n.text(existing.verdict.pastTitle, language: state.language)
                ),
                level: existing.verdict == .scam ? .danger : .safe,
                alertID: alertID
            )
        }
        return outcome
    }

    @discardableResult
    func simulateDecision(by person: Person, _ verdict: Verdict, on alertID: UUID) -> DecisionOutcome {
        relay.submit(GuardianDecision(by: person, verdict: verdict, at: .now), for: alertID)
    }

    func openAlert(_ id: UUID) {
        state.guardianTab = .home
        state.guardianPath = [id]
        state.toast = nil
    }

    func receive(_ event: RelayEvent) {
        switch event {
        case .alert(let alert):
            let isNew = !state.alerts.contains { $0.id == alert.id }
            if let index = state.alerts.firstIndex(where: { $0.id == alert.id }) {
                state.alerts[index] = alert
            } else {
                state.alerts.insert(alert, at: 0)
            }
            if isNew, !state.persona.isParent {
                present(Toast(
                    id: "alert-\(alert.id)",
                    title: L10n.format(
                        "family.alert_title_with_level",
                        fallback: "%@: %@ mungkin sedang ditipu",
                        language: state.language,
                        L10n.text(alert.level.title, language: state.language),
                        alert.parent.name
                    ),
                    body: L10n.text(
                        "Ketuk untuk melihat kalimatnya dan memutuskan.",
                        language: state.language
                    ),
                    level: alert.level,
                    alertID: alert.id
                ))
            }

        case .decided(let alertID, let decision):
            onDecision?()
            state.unanswered.remove(alertID)
            if let index = state.alerts.firstIndex(where: { $0.id == alertID }) {
                state.alerts[index].decision = decision
                if decision.verdict == .safe {
                    feedback.reportFalsePositive(alertID: alertID, signals: state.alerts[index].signals)
                }
            }
            if let index = state.history.firstIndex(where: { $0.id == alertID }) {
                state.history[index].decision = decision
                profile.persist()
            }
            if let session = state.session, session.id == alertID,
               let activityState = currentActivityState?(session) {
                liveActivity.update(activityState)
            }
            if decision.by != state.currentPerson {
                let scam = decision.verdict == .scam
                present(Toast(
                    id: "decision-\(alertID)",
                    title: L10n.format(
                        scam ? "family.decision.scam" : "family.decision.safe",
                        fallback: scam ? "%@: ini penipuan" : "%@: telepon aman",
                        language: state.language,
                        decision.by.name
                    ),
                    body: state.persona.isParent
                        ? L10n.text(
                            scam ? "Tutup telepon sekarang." : "Tetap jangan beri kode atau transfer.",
                            language: state.language
                        )
                        : L10n.format(
                            "family.sent_to",
                            fallback: "Sudah dikirim ke %@.",
                            language: state.language,
                            state.parent.name
                        ),
                    level: scam ? .danger : .safe,
                    alertID: alertID
                ))
            }
        }
    }

    func applyRemoteAlerts(_ remote: [FamilyAlert]) {
        if state.pilotConnected {
            let remoteIDs = Set(remote.map(\.id))
            state.alerts.removeAll { !remoteIDs.contains($0.id) }
        }
        for alert in remote.reversed() {
            let index = state.alerts.firstIndex { $0.id == alert.id }
            let previous = index.map { state.alerts[$0] }
            if let index {
                state.alerts[index] = alert
            } else {
                state.alerts.insert(alert, at: 0)
            }

            if previous == nil, !state.persona.isParent, !alert.callEnded, alert.decision == nil {
                present(Toast(
                    id: "remote-alert-\(alert.id)",
                    title: L10n.format(
                        "family.alert_title_with_level",
                        fallback: "%@: %@ mungkin sedang ditipu",
                        language: state.language,
                        L10n.text(alert.level.title, language: state.language),
                        alert.parent.name
                    ),
                    body: L10n.text(
                        "Ketuk untuk melihat kalimatnya dan memutuskan.",
                        language: state.language
                    ),
                    level: alert.level,
                    alertID: alert.id
                ))
            }
            if previous != nil, previous?.decision == nil, let decision = alert.decision {
                receive(.decided(alertID: alert.id, decision))
            }
        }
    }

    func applyRemoteDecision(_ outcome: DecisionOutcome, alertID: UUID) {
        switch outcome {
        case .accepted(let decision):
            if state.alerts.first(where: { $0.id == alertID })?.decision != decision {
                receive(.decided(alertID: alertID, decision))
            }
        case .alreadyDecided(let decision):
            if let index = state.alerts.firstIndex(where: { $0.id == alertID }) {
                state.alerts[index].decision = decision
            }
            if decision.by != state.currentPerson {
                state.toast = Toast(
                    id: "late-\(alertID)",
                    title: L10n.format(
                        "family.answered_first",
                        fallback: "%@ sudah menjawab lebih dulu",
                        language: state.language,
                        decision.by.name
                    ),
                    body: L10n.format(
                        "family.answer_summary",
                        fallback: "Jawabannya: %@. Cukup satu jawaban.",
                        language: state.language,
                        L10n.text(decision.verdict.pastTitle, language: state.language)
                    ),
                    level: decision.verdict == .scam ? .danger : .safe,
                    alertID: alertID
                )
            }
        case .unknownAlert:
            break
        }
    }
}
