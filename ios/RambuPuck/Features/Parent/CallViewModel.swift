import Foundation
import Observation

/// Mengelola satu siklus telepon, analisis potongan audio, dan Live Activity.
@MainActor
@Observable
final class CallViewModel {
    @ObservationIgnored let state: AppState
    @ObservationIgnored private let analysis: any CallAnalysisSource
    @ObservationIgnored private let family: FamilyViewModel
    @ObservationIgnored private let pilot: PilotViewModel
    @ObservationIgnored private let profile: ProfileViewModel
    @ObservationIgnored private let liveActivity: CallLiveActivity
    @ObservationIgnored private let escalationDelay: Duration
    @ObservationIgnored private let speakerCheckDelay: Duration
    @ObservationIgnored private var listenTask: Task<Void, Never>?
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    @ObservationIgnored private var escalationTask: Task<Void, Never>?
    @ObservationIgnored private var speakerTask: Task<Void, Never>?
    @ObservationIgnored private var analysisSession: (any CallAnalysisSession)?
    @ObservationIgnored private var endingSession: CallSession?

    init(
        state: AppState,
        analysis: any CallAnalysisSource,
        family: FamilyViewModel,
        pilot: PilotViewModel,
        profile: ProfileViewModel,
        liveActivity: CallLiveActivity,
        escalationDelay: Duration,
        speakerCheckDelay: Duration
    ) {
        self.state = state
        self.analysis = analysis
        self.family = family
        self.pilot = pilot
        self.profile = profile
        self.liveActivity = liveActivity
        self.escalationDelay = escalationDelay
        self.speakerCheckDelay = speakerCheckDelay
        family.currentActivityState = { [weak self] session in
            self?.activityState(for: session) ?? Self.fallbackActivityState(for: session)
        }
        family.onDecision = { [weak self] in self?.escalationTask?.cancel() }
    }

    @discardableResult
    func start(_ template: Scenario) -> Task<Void, Never> {
        let localized = Scenario.all(language: state.language).first { $0.id == template.id } ?? template
        let scenario = localized.personalized(parentName: state.parent.name, language: state.language)
        cancelRemoteSession()
        cancelTasks()
        if let old = state.session {
            liveActivity.end(state: activityState(for: old), dismissImmediately: true)
        }
        state.recentProtection = nil
        endingSession = nil

        var session = CallSession(id: UUID(), scenario: scenario, startedAt: .now)
        session.speakerOn = !state.speakerOffNextCall
        state.speakerOffNextCall = false
        state.session = session
        state.persona = .ratna
        state.toast = nil
        state.showCallStatus = false
        state.isCallScreenPresented = true

        guard session.speakerOn else {
            let id = session.id
            let task = Task { [weak self, speakerCheckDelay] in
                try? await Task.sleep(for: speakerCheckDelay)
                guard !Task.isCancelled else { return }
                self?.remindSpeaker(for: id)
            }
            speakerTask = task
            return task
        }
        return beginListening(session)
    }

    @discardableResult
    func startDetectedCall(id: UUID, startedAt: Date) -> Task<Void, Never> {
        if state.session?.id == id, let listenTask { return listenTask }
        cancelRemoteSession()
        cancelTasks()
        if let old = state.session {
            liveActivity.end(state: activityState(for: old), dismissImmediately: true)
        }
        state.recentProtection = nil
        endingSession = nil
        let session = CallSession(
            id: id,
            metadata: .production,
            startedAt: startedAt,
            protectionStatus: .waitingForPuck
        )
        state.session = session
        state.persona = .ratna
        state.toast = nil
        state.showCallStatus = false
        state.isCallScreenPresented = false
        return beginListening(session)
    }

    @discardableResult
    func turnOnSpeaker() -> Task<Void, Never>? {
        guard var current = state.session, !current.speakerOn else { return nil }
        current.speakerOn = true
        state.session = current
        speakerTask?.cancel()
        if state.toast?.id.hasPrefix("speaker-") == true { state.toast = nil }
        return beginListening(current)
    }

    func end() {
        guard let session = state.session else { return }
        endingSession = session
        state.recentProtection = RecentProtection(
            sessionID: session.id,
            level: session.level,
            presentation: .finishing
        )
        let remote = analysisSession
        analysisSession = nil
        escalationTask?.cancel()
        speakerTask?.cancel()
        escalationTask = nil
        speakerTask = nil
        if let remote {
            Task { [weak self] in
                do {
                    try await remote.finish()
                } catch {
                    self?.presentLifecycleFailure(error, sessionID: session.id)
                }
            }
        }

        upsertHistory(for: session)
        if !analysis.usesAuthoritativeRemoteAlerts {
            if let index = state.alerts.firstIndex(where: { $0.id == session.id }) {
                state.alerts[index].callEnded = true
            }
            pilot.end(session.id)
        }

        var final = activityState(for: session)
        final.isListening = false
        liveActivity.end(state: final)

        state.session = nil
        state.showCallStatus = false
        state.isCallScreenPresented = false
        if state.toast?.id.hasPrefix("speaker-") == true { state.toast = nil }
        profile.persist()
    }

    func cancel() {
        let remote = analysisSession
        analysisSession = nil
        cancelTasks()
        if let remote {
            Task { [weak self] in
                do {
                    try await remote.cancel()
                } catch {
                    self?.presentLifecycleFailure(error, sessionID: self?.state.session?.id)
                }
            }
        }
        if let session = state.session {
            liveActivity.end(state: activityState(for: session), dismissImmediately: true)
        }
        state.session = nil
        state.recentProtection = nil
        endingSession = nil
    }

    private func cancelTasks() {
        listenTask?.cancel()
        statusTask?.cancel()
        escalationTask?.cancel()
        speakerTask?.cancel()
        listenTask = nil
        statusTask = nil
        escalationTask = nil
        speakerTask = nil
    }

    private func cancelRemoteSession() {
        guard let remote = analysisSession else { return }
        analysisSession = nil
        Task { [weak self] in
            do {
                try await remote.cancel()
            } catch {
                self?.presentLifecycleFailure(error, sessionID: self?.state.session?.id)
            }
        }
    }

    private func remindSpeaker(for id: UUID) {
        guard let session = state.session, session.id == id, !session.speakerOn else { return }
        profile.present(Toast(
            id: "speaker-\(id)",
            title: "Nyalakan loudspeaker",
            body: "Rambu belum mendengar suara telepon. Ketuk Speaker supaya bisa ikut menjaga.",
            level: .review,
            alertID: nil
        ))
    }

    private func beginListening(_ session: CallSession) -> Task<Void, Never> {
        let context = CallContext(
            id: session.id,
            metadata: session.metadata,
            startedAt: session.startedAt,
            language: state.language
        )
        let sessionID = session.id
        let task = Task { [weak self] in
            do {
                guard let self else { return }
                let remote = try await analysis.start(for: context)
                guard !Task.isCancelled else {
                    try await remote.cancel()
                    return
                }
                let isActive = state.session?.id == sessionID
                let endedBeforeStartCompleted = endingSession?.id == sessionID
                guard isActive || endedBeforeStartCompleted else {
                    try await remote.cancel()
                    return
                }
                if isActive { analysisSession = remote }
                statusTask = Task { [weak self] in
                    for await status in remote.statusUpdates {
                        guard !Task.isCancelled else { return }
                        self?.updateProtectionStatus(status, sessionID: sessionID)
                    }
                }
                if endedBeforeStartCompleted {
                    try await remote.finish()
                }
                for try await chunk in remote.assessments {
                    guard !Task.isCancelled else { return }
                    ingest(chunk, sessionID: sessionID)
                }
                completeEndingSession(sessionID)
            } catch is CancellationError {
                return
            } catch {
                self?.handleAnalysisFailure(error, sessionID: sessionID)
            }
        }
        listenTask = task
        return task
    }

    private func updateProtectionStatus(_ status: ProtectionStatus, sessionID: UUID) {
        if var current = state.session, current.id == sessionID {
            current.protectionStatus = status
            current.isListening = status == .listening || status == .waitingForPuck
            state.session = current
        } else {
            if var finishing = endingSession, finishing.id == sessionID {
                finishing.protectionStatus = status
                finishing.isListening = status == .listening || status == .waitingForPuck
                endingSession = finishing
                if status == .noSpeech { upsertHistory(for: finishing) }
            } else if status == .noSpeech,
                      let index = state.history.firstIndex(where: { $0.id == sessionID }) {
                state.history[index].level = .safe
                state.history[index].signals = []
                state.history[index].evidence = []
                state.history[index].unassessedReason = "Tidak ada suara yang dapat dianalisis."
                profile.persist()
            }
            guard var recent = state.recentProtection, recent.sessionID == sessionID else { return }
            switch status {
            case .waitingForPuck, .listening:
                recent.presentation = .finishing
            case .completed:
                recent.presentation = .completed(recent.level)
            case .noSpeech:
                recent.presentation = .noSpeech
            }
            state.recentProtection = recent
        }
    }

    private func presentLifecycleFailure(_ error: Error, sessionID: UUID?) {
        let failure = analysisFailure(from: error)
        record(failure, sessionID: sessionID)
        profile.present(Toast(
            id: "analysis-lifecycle-\(sessionID?.uuidString ?? UUID().uuidString)",
            title: state.allowsDemoControls ? failure.title : "Analisis belum berhasil",
            body: state.allowsDemoControls ? failure.detail : "Hasil panggilan ini belum tersedia. Periksa koneksi lalu coba lagi.",
            level: .review,
            alertID: nil
        ))
    }

    private func handleAnalysisFailure(_ error: Error, sessionID: UUID) {
        let failure = analysisFailure(from: error)
        if var current = state.session, current.id == sessionID {
            current.isListening = false
            current.analysisFailure = failure
            state.session = current
            escalationTask?.cancel()
            escalationTask = nil
            if liveActivity.isActive {
                liveActivity.update(activityState(for: current))
            }
        } else {
            record(failure, sessionID: sessionID)
        }
        profile.present(Toast(
            id: "analysis-error-\(sessionID)",
            title: state.allowsDemoControls ? failure.title : "Analisis belum berhasil",
            body: state.allowsDemoControls ? failure.detail : "Hasil panggilan ini belum tersedia. Periksa koneksi lalu coba lagi.",
            level: .review,
            alertID: nil
        ))
    }

    private func record(_ failure: AnalysisFailure, sessionID: UUID?) {
        guard let sessionID else { return }
        if var current = state.session, current.id == sessionID {
            current.analysisFailure = failure
            current.isListening = false
            state.session = current
        } else if var recent = state.recentProtection, recent.sessionID == sessionID {
            recent.presentation = .failed(failure)
            state.recentProtection = recent
        }
        if var finishing = endingSession, finishing.id == sessionID {
            finishing.analysisFailure = failure
            finishing.isListening = false
            endingSession = finishing
            upsertHistory(for: finishing)
        }
    }

    private func analysisFailure(from error: Error) -> AnalysisFailure {
        guard let backend = error as? BackendAnalysisError else {
            return AnalysisFailure(
                code: "analysis_failed",
                title: "Analisis panggilan gagal",
                detail: "Rambu tidak dapat menyelesaikan analisis panggilan ini.",
                at: .now
            )
        }
        let detail: String
        if case .http(let status, let message) = backend {
            detail = "\(message) (HTTP \(status))."
        } else {
            detail = backend.detail
        }
        return AnalysisFailure(
            code: backend.code,
            title: "Analisis panggilan gagal",
            detail: detail,
            at: .now
        )
    }

    private func ingest(_ chunk: ChunkAssessment, sessionID: UUID) {
        let ended: Bool
        var current: CallSession
        if let active = state.session, active.id == sessionID {
            current = active
            ended = false
        } else if let finishing = endingSession, finishing.id == sessionID {
            current = finishing
            ended = true
        } else {
            return
        }
        let previous = current.level

        let line = localizedFixtureLine(for: chunk.line, session: current) ?? chunk.line
        current.heard.append(line)
        for signal in chunk.signals where !current.signals.contains(signal) {
            current.signals.append(signal)
        }
        current.level = max(current.level, chunk.level)
        if ended {
            endingSession = current
            if var recent = state.recentProtection, recent.sessionID == sessionID {
                recent.level = current.level
                if case .completed = recent.presentation {
                    recent.presentation = .completed(current.level)
                }
                state.recentProtection = recent
            }
        } else {
            state.session = current
        }

        guard current.level.relaysToGuardians else {
            if ended { upsertHistory(for: current) }
            return
        }
        if !ended, liveActivity.isActive {
            liveActivity.update(activityState(for: current))
        } else if !ended {
            liveActivity.start(
                attributes: RambuCallAttributes(
                    parentName: state.parent.name,
                    channel: current.metadata.channel.short,
                    startedAt: current.startedAt
                ),
                state: activityState(for: current)
            )
        }

        let publishesLocally = !analysis.usesAuthoritativeRemoteAlerts
        let isFirstAlert = publishesLocally && !state.alerts.contains { $0.id == current.id }
        if publishesLocally, current.level > previous || line.isFlagged {
            let alert = makeAlert(from: current)
            family.publish(alert)
            pilot.publish(alert)
        }
        if ended {
            if publishesLocally {
                if let index = state.alerts.firstIndex(where: { $0.id == current.id }) {
                    state.alerts[index].callEnded = true
                }
                pilot.end(current.id)
            }
            upsertHistory(for: current)
        } else if isFirstAlert {
            scheduleEscalation(for: current.id)
        }
        if current.level > previous, state.persona.isParent {
            profile.present(parentWarning(for: current))
        }
    }

    private func localizedFixtureLine(for line: TranscriptLine, session: CallSession) -> TranscriptLine? {
        guard let fixtureID = session.metadata.fixtureID,
              let scenario = Scenario.all(language: state.language)
                .first(where: { $0.id == fixtureID })?
                .personalized(parentName: state.parent.name, language: state.language) else { return nil }
        return scenario.lines.first { $0.id == line.id }
    }

    private func completeEndingSession(_ sessionID: UUID) {
        guard let finishing = endingSession, finishing.id == sessionID else { return }
        upsertHistory(for: finishing)
        endingSession = nil
        profile.persist()
    }

    private func upsertHistory(for session: CallSession) {
        state.history.removeAll { $0.id == session.id }
        let unassessedReason: String?
        if let failure = session.analysisFailure {
            unassessedReason = failure.detail
        } else if session.protectionStatus == .noSpeech {
            unassessedReason = "Tidak ada suara yang dapat dianalisis."
        } else {
            unassessedReason = nil
        }
        let decision = state.alerts.first { $0.id == session.id }?.decision
        state.history.insert(CallRecord(
            id: session.id,
            title: session.metadata.title,
            callerDetail: session.metadata.callerDetail,
            channel: session.metadata.channel,
            startedAt: session.startedAt,
            duration: max(0, Date.now.timeIntervalSince(session.startedAt)),
            level: unassessedReason == nil ? session.level : .safe,
            signals: unassessedReason == nil ? session.signals : [],
            evidence: unassessedReason == nil
                ? session.heard.filter { $0.speaker != .parent && $0.isFlagged }
                : [],
            decision: decision,
            unassessedReason: unassessedReason
        ), at: 0)
    }

    private func scheduleEscalation(for id: UUID) {
        escalationTask?.cancel()
        escalationTask = Task { [weak self, escalationDelay] in
            try? await Task.sleep(for: escalationDelay)
            guard !Task.isCancelled else { return }
            self?.escalate(id)
        }
    }

    private func escalate(_ id: UUID) {
        guard let alert = state.alerts.first(where: { $0.id == id }),
              alert.decision == nil,
              state.session?.id == id else { return }
        state.unanswered.insert(id)
        if state.persona.isParent {
            profile.present(Toast(
                id: "unanswered-\(id)",
                title: "Belum ada jawaban",
                body: "Pengawas belum menjawab. Jangan lakukan tindakan apa pun dulu.",
                level: alert.level,
                alertID: id
            ))
        } else {
            profile.present(Toast(
                id: "unanswered-\(id)",
                title: "\(alert.parent.name) menunggu jawaban",
                body: "Belum ada pengawas yang menjawab peringatan.",
                level: alert.level,
                alertID: id
            ))
        }
    }

    private func makeAlert(from session: CallSession) -> FamilyAlert {
        let existing = state.alerts.first { $0.id == session.id }
        return FamilyAlert(
            id: session.id,
            parent: state.parent,
            callerDetail: session.metadata.callerDetail,
            channel: session.metadata.channel,
            startedAt: session.startedAt,
            raisedAt: existing?.raisedAt ?? .now,
            level: session.level,
            signals: session.signals,
            evidence: session.heard.filter { $0.speaker != .parent && $0.isFlagged },
            recipients: state.guardians,
            decision: existing?.decision
        )
    }

    private func parentWarning(for session: CallSession) -> Toast {
        let language = state.language
        let names = state.guardians.map(\.name).formatted(.list(type: .and).locale(language.locale))
        let delivery = state.guardians.isEmpty
            ? L10n.text("Belum ada pengawas terhubung.", language: language)
            : L10n.format("Sudah dikirim ke %@.", language: language, names)
        let danger = session.level == .danger
        return Toast(
            id: "\(session.id)-\(session.level.rawValue)",
            title: L10n.text(danger ? "Bahaya: terindikasi penipuan" : "Bahaya: telepon mencurigakan", language: language),
            body: danger
                ? L10n.format("Hati-hati. Jangan transfer atau sebut kode. %@", language: language, delivery)
                : L10n.format("%@ Jangan beri data dulu. %@", language: language,
                              L10n.text(session.headline, language: language), delivery),
            level: session.level,
            alertID: session.id
        )
    }

    func activityState(for session: CallSession) -> RambuCallAttributes.ContentState {
        let decision = state.alerts.first { $0.id == session.id }?.decision
        return RambuCallAttributes.ContentState(
            level: session.level,
            headline: session.headline,
            isListening: session.isListening,
            decidedBy: decision?.by.name,
            decisionIsScam: decision.map { $0.verdict == .scam }
        )
    }

    private static func fallbackActivityState(for session: CallSession) -> RambuCallAttributes.ContentState {
        RambuCallAttributes.ContentState(
            level: session.level,
            headline: session.headline,
            isListening: session.isListening,
            decidedBy: nil,
            decisionIsScam: nil
        )
    }
}
