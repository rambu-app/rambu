import Foundation
import Observation

/// Composition root dan routing lintas fitur. Logika fitur tinggal di ViewModel masing-masing.
@MainActor
@Observable
final class AppViewModel {
    @ObservationIgnored let state: AppState
    @ObservationIgnored let onboarding: OnboardingViewModel
    @ObservationIgnored let call: CallViewModel
    @ObservationIgnored let family: FamilyViewModel
    @ObservationIgnored let profile: ProfileViewModel
    @ObservationIgnored let pilot: PilotViewModel
    @ObservationIgnored let feedback: any DetectionFeedback
    @ObservationIgnored private let callActivity: (any CallActivityMonitoring)?
    @ObservationIgnored private let isProtectionConfigured: @Sendable () -> Bool
    @ObservationIgnored private var callActivityTask: Task<Void, Never>?

    init(
        persona: Persona = .ratna,
        onboardingComplete: Bool = false,
        allowsDemoControls: Bool = false,
        analysis: any CallAnalysisSource,
        relay: (any FamilyRelay)? = nil,
        liveActivities: Bool = true,
        notifications: Bool = true,
        speech: Bool = true,
        callActivity: (any CallActivityMonitoring)? = nil,
        isProtectionConfigured: @escaping @Sendable () -> Bool = { false },
        store: LocalStore? = nil,
        pilot: PilotSync? = nil,
        escalationDelay: Duration = .seconds(60),
        speakerCheckDelay: Duration = .seconds(3),
        now: Date = .now
    ) {
        let state = AppState(
            persona: persona,
            onboardingComplete: onboardingComplete,
            allowsDemoControls: allowsDemoControls,
            now: now
        )
        if let saved = store?.load() {
            state.restore(saved)
            // Existing authenticated families will replace any legacy draft on refresh.
            if !allowsDemoControls, pilot?.isConnected == true {
                state.onboardingComplete = saved.onboardingComplete
            }
        }

        let notifier = RambuNotifier(enabled: notifications)
        let profile = ProfileViewModel(
            state: state,
            notifier: notifier,
            narrator: Narrator(enabled: speech),
            network: NetworkMonitor(),
            store: store,
            urgencyFeedback: UrgencyFeedback()
        )
        let activity = CallLiveActivity(enabled: liveActivities)
        let feedback = LocalDetectionFeedback()
        let family = FamilyViewModel(
            state: state,
            relay: relay ?? LocalFamilyRelay(),
            feedback: feedback,
            liveActivity: activity,
            profile: profile,
            present: profile.present
        )
        let pilotViewModel = PilotViewModel(state: state, pilot: pilot, family: family, profile: profile)
        let call = CallViewModel(
            state: state,
            analysis: analysis,
            family: family,
            pilot: pilotViewModel,
            profile: profile,
            liveActivity: activity,
            escalationDelay: escalationDelay,
            speakerCheckDelay: speakerCheckDelay
        )

        self.state = state
        self.profile = profile
        self.onboarding = OnboardingViewModel(state: state, profile: profile)
        self.family = family
        self.pilot = pilotViewModel
        self.call = call
        self.feedback = feedback
        self.callActivity = callActivity
        self.isProtectionConfigured = isProtectionConfigured

        profile.onNotificationOpen { [weak self] id in self?.openFromPush(id) }
        pilotViewModel.start()
        if notifications {
            profile.startNetworkMonitoring()
            Task { await profile.refreshNotificationStatus() }
        }
    }

    func startCallMonitoring() {
        guard callActivityTask == nil, let callActivity else { return }
        callActivityTask = Task { [weak self] in
            do {
                for try await event in callActivity.events {
                    guard !Task.isCancelled, let self else { return }
                    handleCallActivity(event)
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self else { return }
                let detail = (error as? BackendAnalysisError)?.detail
                    ?? "iOS menghentikan pemantauan panggilan."
                profile.present(Toast(
                    id: "call-monitor-error",
                    title: "Pemantauan panggilan berhenti",
                    body: detail,
                    level: .review,
                    alertID: nil
                ))
            }
        }
        callActivity.refresh()
    }

    func refreshCallMonitoring() {
        callActivity?.refresh()
    }

    private func handleCallActivity(_ event: CallActivityEvent) {
        switch event.state {
        case .connected:
            guard state.onboardingComplete, state.persona.isParent else { return }
            guard state.session?.id != event.id else { return }
            guard isProtectionConfigured() else {
                profile.present(Toast(
                    id: "protection-not-configured-\(event.id)",
                    title: "Perlindungan panggilan belum siap",
                    body: "Hubungkan akun orang tua ke server Rambu sebelum menerima panggilan.",
                    level: .review,
                    alertID: nil
                ))
                return
            }
            call.startDetectedCall(id: event.id, startedAt: event.at)
            profile.present(Toast(
                id: "call-detected-\(event.id)",
                title: "Panggilan terdeteksi",
                body: "Menunggu Rambu Puck. Audio belum dianalisis.",
                level: .safe,
                alertID: nil
            ))
        case .ended:
            guard state.session?.id == event.id else { return }
            call.end()
        }
    }

    func switchPersona(_ persona: Persona) {
        state.persona = persona
        state.guardianPath = []
        state.toast = nil
        state.showCallStatus = false
        if persona.isParent, state.session != nil { state.isCallScreenPresented = true }
        profile.persist()
    }

    func resetDemo() {
        call.cancel()
        state.isCallScreenPresented = false
        state.recentProtection = nil
        state.showCallStatus = false
        state.showProfile = false
        state.alerts = []
        state.unanswered = []
        state.history = state.allowsDemoControls ? CallRecord.seed() : []
        state.toast = nil
        state.guardianPath = []
        state.parentTab = .home
        state.guardianTab = .home
        state.persona = .ratna
        state.parent = state.allowsDemoControls ? .ratna : Person(id: "parent-draft", name: "", initial: "", relation: "Orang tua", colorHex: 0x006F63)
        state.guardians = state.allowsDemoControls ? Person.guardians : []
        state.guardianDraft = Person(id: "guardian-draft", name: "", initial: "", relation: "Anak", colorHex: 0x006F63)
        state.extraParents = []
        state.puck = .unpaired
        state.bluetoothOn = true
        state.simulateOffline = false
        state.speakerOffNextCall = false
        state.onboardingComplete = false
        state.onboardingStep = .welcome
        pilot.disconnect()
        profile.clearStoredState()
        UserDefaults.standard.removeObject(forKey: "puckPaired")
        UserDefaults.standard.removeObject(forKey: "puckWifiName")
        UserDefaults.standard.removeObject(forKey: "practiceCallDone")
    }

    func handleIncoming(_ url: URL) {
        guard let code = InviteLink.code(from: url) else { return }
        if !state.onboardingComplete {
            onboarding.handleInvite(code: code)
        } else if !state.persona.isParent, let added = profile.addProtectedParent(code: code) {
            state.toast = Toast(
                id: "joined-\(added.id)",
                title: "Sekarang Anda menjaga \(added.name)",
                body: "Peringatan dari HP \(added.name) akan masuk ke sini.",
                level: .safe,
                alertID: nil
            )
        } else if state.persona.isParent {
            state.toast = Toast(
                id: "link-parent",
                title: "Tautan ini untuk pengawas",
                body: "Kirim ke HP anak Anda.",
                level: .safe,
                alertID: nil
            )
        }
    }

    func openToast(_ toast: Toast) {
        openFromPush(toast.alertID)
    }

    /// Pilot decisions are submitted remotely; the local demo uses the family relay.
    @discardableResult
    func decide(_ verdict: Verdict, on alertID: UUID) -> DecisionOutcome {
        if state.pilotConnected {
            let proposed = GuardianDecision(by: state.currentPerson, verdict: verdict, at: .now)
            Task { [weak self] in
                guard let self else { return }
                _ = await self.pilot.submit(verdict, alertID: alertID)
            }
            return .accepted(proposed)
        }
        return family.decide(verdict, on: alertID)
    }

    func openFromPush(_ id: UUID?) {
        state.toast = nil
        if state.pilotConnected {
            Task { [weak self] in
                guard let self else { return }
                await self.pilot.refresh()
                guard !self.state.persona.isParent, let id else { return }
                self.family.openAlert(id)
            }
        }
        if state.persona.isParent {
            if state.session != nil { state.showCallStatus = true } else { state.parentTab = .history }
        } else if let id, !state.pilotConnected {
            family.openAlert(id)
        }
    }
}
