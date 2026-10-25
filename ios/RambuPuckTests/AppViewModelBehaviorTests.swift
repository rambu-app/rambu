import Foundation
import Testing
@testable import RambuPuck

@MainActor
struct AppViewModelBehaviorTests {
    private func makeModel(persona: Persona = .ratna) -> AppViewModel {
        let model = AppViewModel(
            persona: persona,
            onboardingComplete: true,
            allowsDemoControls: true,
            analysis: ScenarioAnalysis(interval: .zero, initialDelay: .zero),
            liveActivities: false,
            notifications: false,
            speech: false
        )
        model.state.language = .indonesian
        return model
    }

    @Test("English risk warnings are personalized and contain no Indonesian operational copy")
    func englishParentWarning() async throws {
        let model = makeModel()
        model.state.language = .english
        model.state.parent = model.state.parent.renamed("Mrs Taylor")

        await model.call.start(.bankOTP).value

        let warning = try #require(model.state.toast)
        #expect(warning.title == "Danger: possible scam")
        #expect(warning.body == "Be careful. Do not transfer money or share codes. Sent to Sinta and Richard.")
        #expect(model.state.session?.metadata.title == "Caller claiming to be from Sentosa Bank")
        #expect(model.state.session?.heard.first?.text.contains("Mrs Taylor") == true)
    }

    @Test("Telepon wajar tidak pernah dikirim ke pengawas")
    func safeCallIsNotRelayed() async {
        let model = makeModel()
        await model.call.start(.neighbourSafe).value

        #expect(model.state.alerts.isEmpty)
        #expect(model.state.session?.level == .safe)
        // Telepon aman tidak memunculkan push, tetapi tetap tercatat hijau.
        #expect(model.state.toast == nil)
        let before = model.state.history.count
        model.call.end()
        #expect(model.state.history.count == before + 1)
        #expect(model.state.history.first?.historyPresentation == .safe)
    }

    @Test("Orang tua menerima push Bahaya yang menyebut kedua pengawas")
    func parentGetsDangerPush() async throws {
        let model = makeModel()
        await model.call.start(.bankOTP).value

        let push = try #require(model.state.toast)
        #expect(push.level == .danger)
        #expect(push.title.hasPrefix("Bahaya"))
        #expect(push.body.contains("Sinta") && push.body.contains("Richard"))
    }

    @Test("Telepon penipuan sampai ke kedua pengawas beserta kalimat penelepon saja")
    func scamCallReachesBothGuardians() async throws {
        let model = makeModel()
        await model.call.start(.bankOTP).value

        let alert = try #require(model.state.alerts.first)
        #expect(alert.level == .danger)
        #expect(Set(alert.recipients) == [.sinta, .richard])
        #expect(!alert.evidence.isEmpty)
        #expect(alert.evidence.allSatisfy { $0.speaker == .caller && $0.isFlagged })
    }

    @Test("Keputusan pertama berlaku dan mengunci pengawas lain")
    func firstDecisionWins() async throws {
        let model = makeModel()
        await model.call.start(.bankOTP).value
        let id = try #require(model.state.alerts.first?.id)

        model.switchPersona(.sinta)
        guard case .accepted(let first) = model.decide(.scam, on: id) else {
            Issue.record("Keputusan Sinta seharusnya diterima")
            return
        }
        #expect(first.by == .sinta)

        model.switchPersona(.richard)
        let alert = try #require(model.state.alerts.first { $0.id == id })
        #expect(alert.decision?.by == .sinta)
        #expect(model.family.canDecide(alert) == false)

        guard case .alreadyDecided(let existing) = model.decide(.safe, on: id) else {
            Issue.record("Keputusan Richard seharusnya ditolak")
            return
        }
        #expect(existing.by == .sinta)
        #expect(existing.verdict == .scam)
    }

    @Test("Orang tua tidak bisa memberi keputusan untuk dirinya sendiri")
    func parentCannotDecide() async throws {
        let model = makeModel()
        await model.call.start(.bankOTP).value
        let id = try #require(model.state.alerts.first?.id)

        #expect(model.decide(.safe, on: id) == .unknownAlert)
        #expect(model.state.alerts.first?.decision == nil)
    }

    @Test("Keputusan yang masuk tersimpan di riwayat setelah telepon ditutup")
    func decisionIsKeptInHistory() async throws {
        let model = makeModel()
        await model.call.start(.accidentTransfer).value
        let id = try #require(model.state.alerts.first?.id)
        model.family.simulateDecision(by: .richard, .scam, on: id)
        model.call.end()

        let record = try #require(model.state.history.first { $0.id == id })
        #expect(record.decision?.by == .richard)
        #expect(record.level == .danger)
        #expect(model.state.session == nil)
    }

    @Test("Tingkat risiko tidak pernah turun selama satu panggilan")
    func levelIsMonotonic() async throws {
        for scenario in Scenario.all() {
            let context = CallContext(id: UUID(), metadata: scenario.callMetadata, startedAt: .now)
            var levels: [RiskLevel] = []
            for try await chunk in ScenarioAnalysis(interval: .zero, initialDelay: .zero).assessments(for: context) {
                levels.append(chunk.level)
            }
            #expect(levels == levels.sorted(), "Tingkat turun di skenario \(scenario.id)")
        }
    }

    @Test("Setiap tanda penipuan memakai kategori merah; tanpa tanda tetap hijau")
    func riskRules() {
        #expect(RiskRules.level(for: []) == .safe)
        #expect(RiskRules.level(for: [.impersonation]) == .danger)
        #expect(RiskRules.level(for: [.urgency]) == .danger)
        #expect(RiskRules.level(for: [.secretCode]) == .danger)
        #expect(RiskRules.level(for: [.impersonation, .urgency]) == .danger)
    }

    // MARK: Fitur P0 sampai P2

    @Test("Data keluarga dan riwayat tersimpan di HP dan terbaca lagi")
    func stateSurvivesRelaunch() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rambu-\(UUID()).json")
        let store = LocalStore(url: url)
        defer { store.clear() }

        let first = AppViewModel(analysis: ScenarioAnalysis(interval: .zero, initialDelay: .zero),
                             liveActivities: false, notifications: false, speech: false, store: store)
        first.profile.renameParent("Bu Sri")
        first.onboarding.complete(as: .ratna)
        await first.call.start(.bankOTP).value
        first.call.end()

        let second = AppViewModel(
            analysis: ScenarioAnalysis(interval: .zero, initialDelay: .zero),
            liveActivities: false,
            notifications: false,
            speech: false,
            store: store
        )
        #expect(second.state.onboardingComplete)
        #expect(second.state.parent.name == "Bu Sri")
        #expect(second.state.history.first?.level == .danger)
    }

    @Test("Tanpa jawaban pengawas, orang tua diminta menahan diri")
    func unansweredAlertEscalates() async throws {
        let model = AppViewModel(persona: .ratna, onboardingComplete: true,
                             analysis: ScenarioAnalysis(interval: .zero, initialDelay: .zero),
                             liveActivities: false, notifications: false, speech: false,
                             escalationDelay: .milliseconds(50))
        model.state.language = .indonesian
        await model.call.start(.bankOTP).value
        try await Task.sleep(for: .milliseconds(200))

        let id = try #require(model.state.session?.id)
        #expect(model.state.unanswered.contains(id))
        #expect(model.state.toast?.title == "Belum ada jawaban")
        #expect(model.state.toast?.body.contains("Jangan lakukan tindakan apa pun dulu") == true)
    }

    @Test("Loudspeaker mati: Rambu mengingatkan dan baru mendengar setelah dinyalakan")
    func speakerReminder() async throws {
        let model = AppViewModel(persona: .ratna, onboardingComplete: true,
                             analysis: ScenarioAnalysis(interval: .zero, initialDelay: .zero),
                             liveActivities: false, notifications: false, speech: false,
                             speakerCheckDelay: .milliseconds(10))
        model.state.language = .indonesian
        model.state.speakerOffNextCall = true
        await model.call.start(.bankOTP).value

        #expect(model.state.toast?.title == "Nyalakan loudspeaker")
        #expect(model.state.alerts.isEmpty)

        await model.call.turnOnSpeaker()?.value
        #expect(model.state.session?.speakerOn == true)
        #expect(model.state.alerts.first?.level == .danger)
    }

    @Test("Pengawas yang kalah cepat diberi tahu siapa yang menjawab lebih dulu")
    func lateGuardianIsTold() async throws {
        let model = makeModel()
        await model.call.start(.bankOTP).value
        let id = try #require(model.state.alerts.first?.id)
        model.family.simulateDecision(by: .richard, .scam, on: id)

        model.switchPersona(.sinta)
        let outcome = model.decide(.safe, on: id)
        #expect(outcome == .alreadyDecided(try #require(model.state.alerts.first?.decision)))
        #expect(model.state.toast?.title == "Richard sudah menjawab lebih dulu")
    }

    @Test("Tautan undangan dari WhatsApp mengisi kode pengawas")
    func inviteLinkFillsCode() {
        #expect(InviteLink.code(from: URL(string: "rambu://gabung?kode=482913")!) == "482913")
        #expect(InviteLink.code(from: InviteLink.url(code: "715204")) == "715204")
        #expect(InviteLink.code(from: URL(string: "rambu://gabung?kode=12")!) == nil)

        let model = AppViewModel(
            analysis: ScenarioAnalysis(interval: .zero, initialDelay: .zero),
            liveActivities: false,
            notifications: false,
            speech: false
        )
        model.handleIncoming(URL(string: "rambu://gabung?kode=482913")!)
        #expect(model.state.onboardingStep == .guardianProfile)
        #expect(model.state.pendingInviteCode == "482913")
    }

    @Test("Jawaban Aman tercatat sebagai umpan balik dan masuk ringkasan")
    func safeDecisionIsFeedback() async throws {
        let model = makeModel()
        await model.call.start(.courierApp).value
        let id = try #require(model.state.alerts.first?.id)
        model.switchPersona(.sinta)
        model.decide(.safe, on: id)
        model.switchPersona(.ratna)
        model.call.end()

        let feedback = try #require(model.feedback as? LocalDetectionFeedback)
        #expect(feedback.reported == [id])
        let record = try #require(model.state.history.first { $0.id == id })
        #expect(record.decision?.by.name == "Sinta")
        #expect(record.decision?.verdict == .safe)
        #expect(record.incidentSummary.contains("aplikasi"))
    }

    @Test("Pengawas bisa menjaga lebih dari satu orang tua")
    func guardianProtectsSeveralParents() {
        let model = makeModel(persona: .sinta)
        let added = model.profile.addProtectedParent(code: "715204")
        #expect(added?.name == "Pak Hadi")
        #expect(model.state.protectedParents.count == 2)
    }

    @Test("CallKit starts one configured parent session and ends the matching session")
    func callKitCoordinatesProtection() async throws {
        let monitor = FakeCallActivityMonitor()
        let analysis = RecordingCallAnalysisSource(finishStatus: .noSpeech)
        let model = AppViewModel(
            persona: .ratna,
            onboardingComplete: true,
            analysis: analysis,
            liveActivities: false,
            notifications: false,
            speech: false,
            callActivity: monitor,
            isProtectionConfigured: { true }
        )
        model.state.language = .indonesian
        let id = UUID()
        let connected = CallActivityEvent(id: id, state: .connected, at: .now)

        model.startCallMonitoring()
        monitor.send(connected)
        monitor.send(connected)
        try await waitUntil { analysis.startCount == 1 && model.state.session?.id == id }

        #expect(model.state.toast?.title == "Panggilan terdeteksi")
        #expect(model.state.toast?.body.contains("belum dianalisis") == true)
        let remote = try #require(analysis.latestSession)
        remote.send(.listening)
        try await waitUntil { model.state.session?.protectionStatus == .listening }
        #expect(model.state.session?.metadata == .production)

        monitor.send(CallActivityEvent(id: UUID(), state: .ended, at: .now))
        try await Task.sleep(for: .milliseconds(20))
        #expect(model.state.session?.id == id)

        monitor.send(CallActivityEvent(id: id, state: .ended, at: .now))
        try await waitUntil {
            model.state.session == nil
                && remote.didFinish
                && model.state.protectionPresentation == .noSpeech
        }
    }

    @Test("CallKit refuses an unconfigured parent with a visible error")
    func callKitRequiresCredentials() async throws {
        let monitor = FakeCallActivityMonitor()
        let analysis = RecordingCallAnalysisSource()
        let model = AppViewModel(
            persona: .ratna,
            onboardingComplete: true,
            analysis: analysis,
            liveActivities: false,
            notifications: false,
            speech: false,
            callActivity: monitor,
            isProtectionConfigured: { false }
        )
        model.state.language = .indonesian

        model.startCallMonitoring()
        monitor.send(CallActivityEvent(id: UUID(), state: .connected, at: .now))
        try await waitUntil { model.state.toast != nil }

        #expect(analysis.startCount == 0)
        #expect(model.state.session == nil)
        #expect(model.state.toast?.title == "Perlindungan panggilan belum siap")
    }

    @Test("The final puck chunk is retained after CallKit reports the call ended")
    func finalAssessmentAfterCallEndIsRetained() async throws {
        let monitor = FakeCallActivityMonitor()
        let line = TranscriptLine(
            id: 0,
            offset: 0,
            speaker: .unknown,
            text: "Transfer sekarang.",
            flagged: ["Transfer sekarang."],
            signals: [.transfer]
        )
        let analysis = RecordingCallAnalysisSource(
            finishStatus: .completed,
            finishAssessment: ChunkAssessment(line: line, level: .danger, signals: [.transfer])
        )
        let model = AppViewModel(
            persona: .ratna,
            onboardingComplete: true,
            analysis: analysis,
            liveActivities: false,
            notifications: false,
            speech: false,
            callActivity: monitor,
            isProtectionConfigured: { true }
        )
        let id = UUID()

        model.startCallMonitoring()
        monitor.send(CallActivityEvent(id: id, state: .connected, at: .now))
        try await waitUntil { analysis.startCount == 1 && model.state.session?.id == id }
        monitor.send(CallActivityEvent(id: id, state: .ended, at: .now))
        try await waitUntil {
            model.state.alerts.first(where: { $0.id == id })?.level == .danger
                && model.state.history.first(where: { $0.id == id })?.level == .danger
                && model.state.protectionPresentation == .completed(.danger)
        }
    }

    @Test("Returning to the foreground reconciles a missed call-ended event")
    func foregroundRefreshEndsMissingCall() async throws {
        let monitor = FakeCallActivityMonitor()
        let analysis = RecordingCallAnalysisSource(finishStatus: .noSpeech)
        let model = AppViewModel(
            persona: .ratna,
            onboardingComplete: true,
            analysis: analysis,
            liveActivities: false,
            notifications: false,
            speech: false,
            callActivity: monitor,
            isProtectionConfigured: { true }
        )
        let id = UUID()

        model.startCallMonitoring()
        monitor.send(CallActivityEvent(id: id, state: .connected, at: .now))
        try await waitUntil { analysis.startCount == 1 && model.state.session?.id == id }
        monitor.sendOnRefresh(CallActivityEvent(id: id, state: .ended, at: .now))

        model.refreshCallMonitoring()

        try await waitUntil {
            model.state.session == nil
                && analysis.latestSession?.didFinish == true
                && model.state.protectionPresentation == .noSpeech
        }
    }

    @Test("Call monitor failures are visible")
    func callMonitorFailureIsVisible() async throws {
        let monitor = FakeCallActivityMonitor()
        let model = AppViewModel(
            persona: .ratna,
            onboardingComplete: true,
            analysis: RecordingCallAnalysisSource(),
            liveActivities: false,
            notifications: false,
            speech: false,
            callActivity: monitor,
            isProtectionConfigured: { true }
        )
        model.state.language = .indonesian

        model.startCallMonitoring()
        monitor.fail(BackendAnalysisError.transport(detail: "CallKit berhenti."))
        try await waitUntil { model.state.toast != nil }

        #expect(model.state.toast?.title == "Pemantauan panggilan berhenti")
        #expect(model.state.toast?.body == "CallKit berhenti.")
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Condition was not met before timeout")
    }
}
