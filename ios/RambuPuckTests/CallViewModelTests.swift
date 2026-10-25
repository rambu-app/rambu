import Foundation
import Testing
@testable import RambuPuck

@MainActor
struct CallViewModelTests {
    private func makeCall(
        analysis: any CallAnalysisSource = ScenarioAnalysis(interval: .zero, initialDelay: .zero),
        escalationDelay: Duration = .seconds(60),
        speakerCheckDelay: Duration = .seconds(3)
    ) -> (AppState, CallViewModel) {
        let state = AppState(onboardingComplete: true, language: .indonesian, allowsDemoControls: true)
        let profile = ProfileViewModel(
            state: state,
            notifier: RambuNotifier(enabled: false),
            narrator: Narrator(enabled: false),
            network: NetworkMonitor(),
            store: nil
        )
        let activity = CallLiveActivity(enabled: false)
        let family = FamilyViewModel(
            state: state,
            relay: LocalFamilyRelay(),
            feedback: LocalDetectionFeedback(),
            liveActivity: activity,
            profile: profile,
            present: profile.present
        )
        let pilot = PilotViewModel(state: state, pilot: nil, family: family, profile: profile)
        let call = CallViewModel(
            state: state,
            analysis: analysis,
            family: family,
            pilot: pilot,
            profile: profile,
            liveActivity: activity,
            escalationDelay: escalationDelay,
            speakerCheckDelay: speakerCheckDelay
        )
        return (state, call)
    }

    @Test("CallViewModel meneruskan telepon berbahaya ke keluarga")
    func dangerousCallPublishesAlert() async throws {
        let (state, call) = makeCall()

        await call.start(.bankOTP).value

        #expect(state.session?.level == .danger)
        #expect(try #require(state.alerts.first).level == .danger)
        #expect(state.toast?.title.hasPrefix("Bahaya") == true)
    }

    @Test("Mengakhiri telepon membatalkan pengingat dan eskalasi lama")
    func endingCallCancelsDelayedTasks() async {
        let (state, call) = makeCall(
            escalationDelay: .milliseconds(40),
            speakerCheckDelay: .milliseconds(40)
        )
        state.speakerOffNextCall = true
        let delayedSpeaker = call.start(.bankOTP)

        call.end()
        await delayedSpeaker.value
        try? await Task.sleep(for: .milliseconds(100))

        #expect(state.session == nil)
        #expect(state.toast == nil)
        #expect(state.unanswered.isEmpty)
    }

    @Test("Semua kegagalan backend terlihat tanpa peringatan atau riwayat palsu")
    func backendFailuresAreVisibleAndDoNotCreateRisk() async throws {
        let failures: [BackendAnalysisError] = [
            .transport(detail: "Server http://10.0.0.8:8000 tidak dapat dihubungi."),
            .http(status: 503, detail: "Langflow belum siap."),
            .decoding,
            .schema(detail: "Bukti analisis tidak sesuai transkrip."),
            .session(code: "analysis_timeout", detail: "Langflow tidak merespons."),
        ]

        for error in failures {
            let source = CountingFailureSource(error: error)
            let (state, call) = makeCall(analysis: source)
            let historyCount = state.history.count

            await call.start(.bankOTP).value

            let session = try #require(state.session)
            let failure = try #require(session.analysisFailure)
            #expect(session.isListening == false)
            #expect(failure.code == error.code)
            #expect(failure.title == "Analisis panggilan gagal")
            #expect(state.toast?.title == failure.title)
            #expect(state.toast?.body == failure.detail)
            if case .http(let status, _) = error {
                #expect(failure.detail.contains("HTTP \(status)"))
            }
            #expect(state.alerts.isEmpty)

            call.end()
            #expect(state.history.count == historyCount + 1)
            #expect(state.history.first?.signals.isEmpty == true)
            #expect(state.history.first?.evidence.isEmpty == true)
            #expect(state.history.first?.unassessedReason == failure.detail)
        }
    }

    @Test("Telepon aman masuk sebagai riwayat hijau")
    func testEndingSafeCallAddsGreenHistory() async throws {
        let (state, call) = makeCall()
        let historyCount = state.history.count

        await call.start(.neighbourSafe).value
        call.end()

        let record = try #require(state.history.first)
        #expect(state.history.count == historyCount + 1)
        #expect(record.level == .safe)
        #expect(record.unassessedReason == nil)
        #expect(record.historyPresentation == .safe)
    }

    @Test("Telepon gagal masuk sebagai riwayat yang belum dapat dinilai")
    func testEndingFailedCallAddsUnassessedHistory() async throws {
        let source = CountingFailureSource(
            error: .session(code: "analysis_timeout", detail: "Analisis panggilan gagal.")
        )
        let (state, call) = makeCall(analysis: source)

        await call.start(.bankOTP).value
        call.end()

        let record = try #require(state.history.first)
        #expect(record.historyPresentation == .unassessed)
        #expect(record.unassessedReason == "Analisis panggilan gagal.")
        #expect(record.signals.isEmpty)
        #expect(record.evidence.isEmpty)
    }

    @Test("Telepon tanpa suara masuk sebagai riwayat yang belum dapat dinilai")
    func testNoSpeechCallAddsUnassessedHistory() async throws {
        let source = RecordingCallAnalysisSource()
        let (state, call) = makeCall(analysis: source)
        let task = call.start(.neighbourSafe)
        while source.latestSession == nil { await Task.yield() }
        source.latestSession?.send(.noSpeech)
        await Task.yield()

        call.end()
        await task.value

        let record = try #require(state.history.first)
        #expect(record.historyPresentation == .unassessed)
        #expect(record.unassessedReason == "Tidak ada suara yang dapat dianalisis.")
        #expect(record.signals.isEmpty)
        #expect(record.evidence.isEmpty)
    }

    @Test("Riwayat versi TestFlight lama tetap terbaca sebagai hasil penilaian")
    func testLegacyCallRecordDecodesAsAssessed() throws {
        struct LegacyRecord: Encodable {
            let id: UUID
            let title: String
            let callerDetail: String
            let channel: CallChannel
            let startedAt: Date
            let duration: TimeInterval
            let level: RiskLevel
            let signals: [SignalKind]
            let evidence: [TranscriptLine]
            let decision: GuardianDecision?
        }
        let legacy = LegacyRecord(
            id: UUID(),
            title: "Telepon lama",
            callerDetail: "Nomor tidak tersedia",
            channel: .cellular,
            startedAt: .now,
            duration: 30,
            level: .review,
            signals: [.urgency],
            evidence: [],
            decision: nil
        )

        let record = try JSONDecoder().decode(CallRecord.self, from: JSONEncoder().encode(legacy))

        #expect(record.unassessedReason == nil)
        #expect(record.historyPresentation == .review)
    }

    @Test("Mencoba lagi membuat sesi baru dan menghapus kegagalan lama")
    func retryStartsCleanSession() async throws {
        let source = CountingFailureSource(
            error: .transport(detail: "Server Rambu tidak dapat dihubungi.")
        )
        let (state, call) = makeCall(analysis: source)

        await call.start(.bankOTP).value
        let first = try #require(state.session)
        #expect(first.analysisFailure != nil)

        await call.start(.bankOTP).value
        let second = try #require(state.session)

        #expect(second.id != first.id)
        #expect(source.invocationCount == 2)
        #expect(second.analysisFailure?.code == "transport")
    }

    @Test("Detected production call starts neutral protection without fake call UI")
    func detectedCallDoesNotPresentScenarioScreen() async throws {
        let (state, call) = makeCall()
        let callID = UUID()

        await call.startDetectedCall(id: callID, startedAt: .now).value

        let session = try #require(state.session)
        #expect(session.id == callID)
        #expect(session.metadata.fixtureID == nil)
        #expect(session.metadata.callerDetail == "Nomor tidak tersedia")
        #expect(state.isCallScreenPresented == false)
    }

    @Test("Backend-authoritative protection does not create a second phone alert")
    func authoritativeProtectionDoesNotRepublishAlert() async throws {
        let line = TranscriptLine(
            id: 0,
            offset: 0,
            speaker: .unknown,
            text: "Sebutkan kode OTP dari SMS.",
            flagged: ["kode OTP"],
            signals: [.secretCode]
        )
        let source = RecordingCallAnalysisSource(
            finishStatus: .completed,
            finishAssessment: ChunkAssessment(
                line: line,
                level: .danger,
                signals: [.secretCode]
            ),
            usesAuthoritativeRemoteAlerts: true
        )
        let (state, call) = makeCall(analysis: source)
        let listening = call.start(.bankOTP)
        while source.latestSession == nil { await Task.yield() }

        call.end()
        await listening.value

        #expect(state.alerts.isEmpty)
        #expect(state.history.first?.level == .danger)
        #expect(state.toast?.level == .danger)
    }
}
