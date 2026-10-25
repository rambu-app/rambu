import Foundation
import Testing
@testable import RambuPuck

@MainActor
struct AppStateTests {
    @Test("Device language selects English only for an English preference")
    func defaultsLanguageFromDevicePreference() {
        #expect(AppLanguage.preferred(from: ["en-US", "id-ID"]) == .english)
        #expect(AppLanguage.preferred(from: ["id-ID", "en-US"]) == .indonesian)
        #expect(AppLanguage.preferred(from: ["fr-FR"]) == .indonesian)
        #expect(AppLanguage.preferred(from: []) == .indonesian)
    }

    @Test("Saved language restores without changing user data")
    func restoresExplicitLanguage() throws {
        let saved = SavedState(
            onboardingComplete: true,
            persona: .ratna,
            parent: .ratna,
            guardians: Person.guardians,
            extraParents: [],
            history: [],
            puck: .demo,
            narrationEnabled: true,
            language: .english
        )
        let data = try JSONEncoder().encode(saved)
        let decoded = try JSONDecoder().decode(SavedState.self, from: data)
        let state = AppState(language: .indonesian, allowsDemoControls: true)

        state.restore(decoded)

        #expect(state.language == .english)
        #expect(state.parent == .ratna)
        #expect(state.guardians == Person.guardians)
        #expect(state.onboardingComplete)
    }

    @Test("Saved state from before language support remains Indonesian")
    func oldSaveDefaultsToIndonesian() throws {
        let json = """
        {
          "onboardingComplete": false,
          "persona": "ratna",
          "parent": {"id":"parent-draft","name":"","initial":"","relation":"Orang tua","colorHex":28515},
          "guardians": [],
          "extraParents": [],
          "history": [],
          "puck": {"isPaired":false,"isConnected":false,"battery":0,"isCharging":false,"name":"Rambu Puck","serial":"","firmware":""},
          "narrationEnabled": true
        }
        """

        let decoded = try JSONDecoder().decode(SavedState.self, from: Data(json.utf8))

        #expect(decoded.language == .indonesian)
    }

    @Test("Changing language preserves family and history state")
    func languageChangeDoesNotResetState() {
        let state = AppState(language: .indonesian, allowsDemoControls: true)
        let history = state.history
        let parent = state.parent
        let guardians = state.guardians

        state.language = .english

        #expect(state.history == history)
        #expect(state.parent == parent)
        #expect(state.guardians == guardians)
    }

    @Test("English scam scenarios use English copy and the protected parent's name")
    func englishScenariosArePersonalized() throws {
        let template = try #require(Scenario.all(language: .english).first { $0.id == "bank-otp" })
        let scenario = template.personalized(parentName: "Mrs Taylor", language: .english)

        #expect(scenario.title == "Caller claiming to be from Sentosa Bank")
        #expect(scenario.lines.first?.text.contains("Mrs Taylor") == true)
        #expect(scenario.lines.first?.text.contains("Ibu Ratna") == false)
        #expect(scenario.lines.flatMap(\.signals).contains(.impersonation))
        #expect(scenario.lines.flatMap(\.signals).contains(.secretCode))
    }

    @Test("English resources localize dynamic application copy")
    func englishResourceLookup() {
        #expect(L10n.text("Profil", language: .english) == "Profile")
        #expect(L10n.text("Profil", language: .indonesian) == "Profil")
    }

    @Test("Compact evidence groups contained excerpts but preserves distinct signals and original source")
    func groupsOverlappingEvidenceWithoutRewritingSource() {
        let lines = [
            TranscriptLine(id: 0, offset: 0, speaker: .unknown, text: "tolong disebutkan aja Bu", flagged: [], signals: [.secretCode]),
            TranscriptLine(id: 1, offset: 5, speaker: .unknown, text: "nanti tolong disebutkan aja Bu apakah Masuk", flagged: [], signals: [.secretCode]),
            TranscriptLine(id: 2, offset: 10, speaker: .unknown, text: "tolong disebutkan aja Bu", flagged: [], signals: [.urgency]),
            TranscriptLine(id: 3, offset: 15, speaker: .parent, text: "tolong disebutkan aja Bu", flagged: [], signals: [.secretCode]),
        ]
        let compact = TranscriptLine.groupedForDisplay(lines)
        #expect(compact.map(\.id) == [1, 2, 3])
        #expect(compact[0].text == "nanti tolong disebutkan aja Bu apakah Masuk")
        #expect(lines.count == 4)
        #expect(lines[0].text == "tolong disebutkan aja Bu")
    }

    @Test("Evidence grouping does not merge similar but contradictory statements")
    func keepsContradictoryEvidence() {
        let lines = [
            TranscriptLine(id: 0, offset: 0, speaker: .unknown, text: "beri kode", flagged: [], signals: [.secretCode]),
            TranscriptLine(id: 1, offset: 5, speaker: .unknown, text: "jangan beri kode", flagged: [], signals: [.secretCode]),
        ]
        #expect(TranscriptLine.groupedForDisplay(lines).count == 2)
    }

    @Test("Long overlapping excerpts retain Indonesian negative context")
    func preservesNegativeContextInLongExcerpts() {
        for negative in ["belum", "tanpa", "gak", "ga"] {
            let lines = [
                TranscriptLine(id: 0, offset: 0, speaker: .unknown, text: "diminta memberikan kode OTP", flagged: [], signals: [.secretCode]),
                TranscriptLine(id: 1, offset: 5, speaker: .unknown, text: "\(negative) diminta memberikan kode OTP", flagged: [], signals: [.secretCode]),
            ]
            #expect(TranscriptLine.groupedForDisplay(lines).count == 2)
        }
    }

    @Test("Invitation becomes unshareable at server expiry and old identities do not get invented validity")
    func invitationValidityUsesRealExpiry() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(InviteValidity(expiresAt: now.addingTimeInterval(60), now: now).canShare)
        #expect(!InviteValidity(expiresAt: now, now: now).canShare)
        #expect(!InviteValidity(expiresAt: now.addingTimeInterval(-1), now: now).canShare)
        #expect(!InviteValidity(expiresAt: nil, now: now).canShare)
    }

    @Test("History summary separates machine interpretation from caller attribution and metadata")
    func summaryIsInterpretationNotVerifiedSpeech() {
        let record = CallRecord(id: UUID(), title: "Panggilan", callerDetail: "Nomor tidak tersedia", channel: .cellular,
                                startedAt: .now, duration: 259, level: .review,
                                signals: [.secretCode, .urgency], evidence: [], decision: nil)
        #expect(!record.incidentSummary.contains("Penelepon meminta"))
        #expect(!record.incidentSummary.contains("Nomor tidak tersedia"))
        #expect(!record.incidentSummary.contains("4 mnt"))
        #expect(record.incidentSummary.contains("OTP"))
    }
    @Test("Fresh installation does not invent family members or calls")
    func freshInstallationHasNoSamples() {
        let state = AppState()
        #expect(state.history.isEmpty)
        #expect(state.guardians.isEmpty)
        #expect(state.parent.name.isEmpty)
        #expect(!state.puck.isConnected)
    }
    @Test("State bersama menghitung data tampilan dari satu sumber")
    func derivesSharedPresentationState() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let state = AppState(persona: .sinta, onboardingComplete: true, allowsDemoControls: true, now: now)
        let extraParent = Person(id: "hadi", name: "Pak Hadi", initial: "H", relation: "Ayah", colorHex: 0x8A5A12)
        state.extraParents = [extraParent]

        let session = CallSession(id: UUID(), scenario: .bankOTP, startedAt: now)
        state.session = session
        state.alerts = [FamilyAlert(
            id: session.id,
            parent: .ratna,
            callerDetail: "Nomor tidak dikenal",
            channel: .cellular,
            startedAt: now,
            raisedAt: now,
            level: .danger,
            signals: [.secretCode],
            evidence: [],
            recipients: Person.guardians,
            decision: nil
        )]

        #expect(state.currentPerson == .sinta)
        #expect(state.protectedParents == [.ratna, extraParent])
        #expect(state.activeAlert?.id == session.id)
        #expect(state.featuredAlert?.id == session.id)
        #expect(state.otherGuardians(than: .sinta) == [.richard])

        state.alerts[0].decision = GuardianDecision(by: .sinta, verdict: .scam, at: now)
        #expect(state.featuredAlert == nil)
        #expect(state.activeAlert?.decision?.verdict == .scam)
        #expect(HistoryList.handledAlerts(state.alerts, records: []).map(\.id) == [session.id])
        #expect(state.alerts[0].callEnded == false)
        let completed = CallRecord(id: session.id, title: "Panggilan", callerDetail: "Tidak tersedia",
                                   channel: .cellular, startedAt: now, duration: 60, level: .danger,
                                   signals: [.secretCode], evidence: [], decision: state.alerts[0].decision)
        #expect(HistoryList.handledAlerts(state.alerts, records: [completed]).isEmpty)

        state.persona = .ratna
        state.notificationsAuthorized = false
        state.isOnline = false
        state.bluetoothOn = false
        #expect(state.issues == [.notificationsOff, .offline, .bluetoothOff])
    }

    @Test("SavedState pulih tanpa mengubah skema atau nilai")
    func restoresExistingSavedState() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let renamedParent = Person.ratna.renamed("Bu Sri")
        let extraParent = Person(id: "hadi", name: "Pak Hadi", initial: "H", relation: "Ayah", colorHex: 0x8A5A12)
        let saved = SavedState(
            onboardingComplete: true,
            persona: .richard,
            parent: renamedParent,
            guardians: [.sinta, .richard],
            extraParents: [extraParent],
            history: CallRecord.seed(now: now),
            puck: .demo,
            narrationEnabled: false
        )

        let state = AppState(persona: .ratna, onboardingComplete: false, allowsDemoControls: true, now: now)
        state.restore(saved)

        #expect(state.savedState == saved)
    }

    @Test("Restore removes bundled samples and preserves real calls")
    func restoresRealHistoryWithoutBundledSamples() {
        let real = CallRecord(id: UUID(), title: "Panggilan WhatsApp", callerDetail: "Kontak WhatsApp",
                              channel: .whatsapp, startedAt: .now, duration: 30,
                              level: .safe, signals: [], evidence: [], decision: nil)
        let state = AppState()
        state.restore(SavedState(onboardingComplete: true, persona: .ratna, parent: .ratna,
                                 guardians: Person.guardians, extraParents: [],
                                 history: CallRecord.seed() + [real], puck: .demo, narrationEnabled: true))
        #expect(state.history == [real])
        #expect(state.guardians.isEmpty)
        #expect(!state.puck.isConnected)
        #expect(state.parent.name.isEmpty)
        #expect(!state.onboardingComplete)
    }

    @Test("Upgrade preserves a real parent even when named like a sample")
    func keepsAuthenticatedParentIdentity() {
        let parent = Person(id: "parent-real", name: "Ibu Ratna", initial: "R", relation: "Orang tua", colorHex: 0x006F63)
        let state = AppState()
        state.restore(SavedState(onboardingComplete: true, persona: .ratna, parent: parent,
                                 guardians: [], extraParents: [], history: [], puck: .unpaired, narrationEnabled: true))
        #expect(state.parent == parent)
        #expect(state.onboardingComplete)
    }

    @Test("History hides technical server diagnostics")
    func historySummaryDoesNotExposeServerDiagnostics() {
        let record = CallRecord(id: UUID(), title: "Panggilan", callerDetail: "Kontak", channel: .whatsapp,
                                startedAt: .now, duration: 60, level: .safe, signals: [], evidence: [],
                                decision: nil, unassessedReason: "Respons Langflow tidak sesuai kontrak Rambu. HTTP 502")
        #expect(!record.incidentSummary.contains("Langflow"))
        #expect(!record.incidentSummary.contains("HTTP"))
        #expect(record.historyPresentation == .unassessed)
    }

    @Test("Protection presentation represents every production session state")
    func protectionPresentationStates() {
        let state = AppState(persona: .ratna, onboardingComplete: true)
        #expect(state.allowsDemoControls == false)
        #expect(state.protectionPresentation == .setupRequired)

        state.pilotConnected = true
        state.pilotRole = "parent"
        #expect(state.protectionPresentation == .monitoring)

        var session = CallSession(id: UUID(), metadata: .production, startedAt: .now)
        state.session = session
        #expect(state.protectionPresentation == .waitingForPuck)

        session.protectionStatus = .listening
        state.session = session
        #expect(state.protectionPresentation == .listening)

        let failure = AnalysisFailure(
            code: "analysis_timeout",
            title: "Analisis panggilan gagal",
            detail: "Langflow tidak merespons.",
            at: .now
        )
        session.analysisFailure = failure
        state.session = session
        #expect(state.protectionPresentation == .failed(failure))

        session.analysisFailure = nil
        session.protectionStatus = .completed
        session.level = .review
        state.session = session
        #expect(state.protectionPresentation == .completed(.review))

        session.protectionStatus = .noSpeech
        state.session = session
        #expect(state.protectionPresentation == .noSpeech)
    }
}
