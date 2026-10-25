import Foundation
import Observation

enum PilotServerStatus: Sendable {
    case unknown, reachable, unavailable

    var message: String {
        switch self {
        case .unknown: "Memeriksa koneksi server…"
        case .reachable: "Server dapat dihubungi"
        case .unavailable: "Tidak dapat terhubung ke server"
        }
    }
}

enum FamilySessionStatus: String, Sendable {
    case unknown, idle, waitingForPuck = "waiting_for_puck", listening, finishing

    var message: String {
        switch self {
        case .unknown: "Status belum tersedia"
        case .idle: "Tidak ada sesi analisis aktif"
        case .waitingForPuck: "Menunggu analisis"
        case .listening: "Analisis sedang berjalan"
        case .finishing: "Menyelesaikan analisis"
        }
    }
}

enum ProtectionPresentation: Equatable, Sendable {
    case setupRequired
    case monitoring
    case waitingForPuck
    case listening
    case finishing
    case failed(AnalysisFailure)
    case completed(RiskLevel)
    case noSpeech
}

struct RecentProtection: Equatable, Sendable {
    let sessionID: UUID
    var level: RiskLevel
    var presentation: ProtectionPresentation
}

/// Satu sumber kebenaran yang diamati seluruh fitur Rambu.
/// Objek ini hanya menyimpan state dan nilai turunan; efek samping tetap milik ViewModel.
@MainActor
@Observable
final class AppState {
    var persona: Persona
    var language: AppLanguage
    var onboardingComplete: Bool
    var onboardingStep: OnboardingStep = .welcome
    var puck: PuckState

    var parent: Person = .ratna
    var guardians: [Person] = Person.guardians
    var guardianDraft = Person(id: "guardian-draft", name: "", initial: "", relation: "Anak", colorHex: 0x006F63)
    var extraParents: [Person] = []

    var session: CallSession?
    var recentProtection: RecentProtection?
    var isCallScreenPresented = false
    var alerts: [FamilyAlert] = []
    var history: [CallRecord]
    var unanswered: Set<UUID> = []

    var parentTab: ParentTab = .home
    var guardianTab: GuardianTab = .home
    var guardianPath: [UUID] = []
    var showDemoSheet = false
    var showProfile = false
    var showCallStatus = false
    var toast: Toast?

    var narrationEnabled = true
    var notificationsAuthorized = false
    var isOnline = true
    var pendingInviteCode: String?
    var pilotConnected = false
    var pilotServerStatus: PilotServerStatus = .unknown
    var familySessionStatus: FamilySessionStatus?
    var pilotInviteCode: String?
    var pilotInviteExpiresAt: Date?
    var pilotRole: String?
    var pilotError: String?
    let pilotServerURL = RambuServer.url

    var simulateOffline = false
    var bluetoothOn = true
    var speakerOffNextCall = false
    var hidesNotificationIssue = false
    let allowsDemoControls: Bool

    init(
        persona: Persona = .ratna,
        onboardingComplete: Bool = false,
        language: AppLanguage = .preferred(),
        allowsDemoControls: Bool = false,
        now: Date = .now
    ) {
        self.persona = persona
        self.language = language
        self.onboardingComplete = onboardingComplete
        self.allowsDemoControls = allowsDemoControls
        puck = allowsDemoControls && onboardingComplete ? .demo : .unpaired
        history = allowsDemoControls ? CallRecord.seed(now: now) : []
        if !allowsDemoControls {
            parent = Person(id: "parent-draft", name: "", initial: "", relation: "Orang tua", colorHex: 0x006F63)
            guardians = []
        }
    }

    var currentPerson: Person { person(for: persona) }

    var guardianSessionStatus: FamilySessionStatus {
        if allowsDemoControls { return session == nil ? .idle : .listening }
        guard pilotConnected, isOnline, pilotServerStatus == .reachable else { return .unknown }
        return familySessionStatus ?? .unknown
    }

    func person(for persona: Persona) -> Person {
        switch persona {
        case .ratna: parent
        case .sinta: guardians.first ?? (allowsDemoControls ? .sinta : guardianDraft)
        case .richard: guardians.dropFirst().first ?? (allowsDemoControls ? .richard : guardianDraft)
        }
    }

    var protectedParents: [Person] { [parent] + extraParents }

    var protectionPresentation: ProtectionPresentation {
        if let observed = session { return presentation(for: observed) }
        if let recentProtection { return recentProtection.presentation }
        return pilotConnected && pilotRole == "parent" ? .monitoring : .setupRequired
    }

    private func presentation(for observed: CallSession) -> ProtectionPresentation {
        if let failure = observed.analysisFailure { return .failed(failure) }
        switch observed.protectionStatus {
        case .waitingForPuck: return .waitingForPuck
        case .listening: return .listening
        case .completed: return .completed(observed.level)
        case .noSpeech: return .noSpeech
        }
    }

    var activeAlert: FamilyAlert? {
        guard let id = session?.id else { return nil }
        return alerts.first { $0.id == id }
    }

    var featuredAlert: FamilyAlert? {
        alerts.first { $0.decision == nil }
    }

    func otherGuardians(than person: Person) -> [Person] {
        guardians.filter { $0 != person }
    }

    var issues: [SystemIssue] {
        guard onboardingComplete else { return [] }
        var values: [SystemIssue] = []
        if !notificationsAuthorized && !hidesNotificationIssue { values.append(.notificationsOff) }
        if !isOnline || simulateOffline { values.append(.offline) }
        if persona.isParent && allowsDemoControls {
            if !bluetoothOn {
                values.append(.bluetoothOff)
            } else if !puck.isConnected {
                values.append(.puckDisconnected)
            } else if puck.battery <= 20 {
                values.append(.puckLowBattery)
            }
        }
        return values
    }

    var savedState: SavedState {
        SavedState(
            onboardingComplete: onboardingComplete,
            persona: persona,
            parent: parent,
            guardians: guardians,
            extraParents: extraParents,
            history: history,
            puck: puck,
            narrationEnabled: narrationEnabled,
            language: language
        )
    }

    func restore(_ saved: SavedState) {
        onboardingComplete = saved.onboardingComplete
        persona = saved.persona
        parent = saved.parent
        guardians = saved.guardians
        extraParents = saved.extraParents
        history = saved.history
        puck = saved.puck
        narrationEnabled = saved.narrationEnabled
        language = saved.language
        if !allowsDemoControls {
            if parent.id == Person.ratna.id {
                parent = Person(id: "parent-draft", name: "", initial: "", relation: "Orang tua", colorHex: 0x006F63)
            }
            history.removeAll { $0.isSampleRecord }
            guardians.removeAll { ["sinta", "richard"].contains($0.id) }
            extraParents.removeAll { ["hadi", "lies"].contains($0.id) }
            puck = .unpaired
            if currentPerson.name.isEmpty { onboardingComplete = false }
        }
    }
}
