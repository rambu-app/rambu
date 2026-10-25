import Foundation
import Observation

/// Mengelola sinkronisasi pilot dua iPhone tanpa mencampurnya dengan UI profil.
@MainActor
@Observable
final class PilotViewModel {
    @ObservationIgnored let state: AppState
    @ObservationIgnored private let pilot: PilotSync?
    @ObservationIgnored private let family: FamilyViewModel
    @ObservationIgnored private let profile: ProfileViewModel

    init(state: AppState, pilot: PilotSync?, family: FamilyViewModel, profile: ProfileViewModel) {
        self.state = state
        self.pilot = pilot
        self.family = family
        self.profile = profile
    }

    func start() {
        pilot?.updateLanguage(state.language)
        pilot?.onProfile = { [weak self] value in self?.applyProfile(value) }
        pilot?.onAlerts = { [weak self] values in self?.applyAlerts(values) }
        pilot?.onHistory = { [weak self] values in self?.applyHistory(values) }
        pilot?.onError = { [weak state] message in state?.pilotError = message }
        pilot?.onServerStatus = { [weak state] status in state?.pilotServerStatus = status }
        state.pilotConnected = pilot?.isConnected == true
        state.pilotInviteCode = pilot?.inviteCode
        state.pilotInviteExpiresAt = pilot?.inviteExpiresAt
        state.pilotRole = pilot?.credentials?.member.role
        pilot?.start()
    }

    func updateLanguage() {
        pilot?.updateLanguage(state.language)
    }

    func createFamily() async -> Bool {
        guard let pilot else { return false }
        state.pilotError = nil
        do {
            let code = try await pilot.createFamily(serverURL: state.pilotServerURL, parentName: state.parent.name)
            state.pilotConnected = true
            state.pilotRole = "parent"
            state.pilotInviteCode = code
            state.pilotInviteExpiresAt = pilot.inviteExpiresAt
            return true
        } catch {
            state.pilotError = "Kode undangan belum berhasil dibuat. \(PilotAPIError.displayMessage(for: error))"
            return false
        }
    }

    func joinFamily(code: String) async -> Bool {
        guard let pilot else { return false }
        state.pilotError = nil
        do {
            let me = state.currentPerson
            try await pilot.joinFamily(
                serverURL: state.pilotServerURL,
                code: code,
                name: me.name,
                relation: me.relation
            )
            state.pilotConnected = true
            state.pilotRole = "guardian"
            state.pilotInviteCode = nil
            state.pilotInviteExpiresAt = nil
            state.persona = .sinta
            profile.persist()
            return true
        } catch {
            state.pilotError = PilotAPIError.displayMessage(for: error)
            return false
        }
    }

    func renewInvite() async {
        guard let pilot else { return }
        state.pilotError = nil
        do {
            state.pilotInviteCode = try await pilot.renewInvite()
            state.pilotInviteExpiresAt = pilot.inviteExpiresAt
        } catch {
            state.pilotError = "Kode baru belum berhasil dibuat. \(PilotAPIError.displayMessage(for: error))"
        }
    }

    /// Token baru untuk puck keluarga ini. Dikirim ke puck lewat Bluetooth, bukan ditulis di firmware.
    func puckToken() async -> String? {
        guard let pilot, state.pilotConnected, state.persona.isParent else { return nil }
        return try? await pilot.pairPuck()
    }

    func disconnect() {
        pilot?.disconnect()
        state.pilotConnected = false
        state.pilotInviteCode = nil
        state.pilotInviteExpiresAt = nil
        state.pilotRole = nil
        state.pilotServerStatus = .unknown
        state.familySessionStatus = nil
        state.pilotError = nil
    }

    func refresh() async {
        await pilot?.refresh()
    }

    func publish(_ alert: FamilyAlert) {
        pilot?.publish(alert)
    }

    func submit(_ verdict: Verdict, alertID: UUID) async -> DecisionOutcome? {
        guard let outcome = await pilot?.submit(verdict, alertID: alertID) else { return nil }
        family.applyRemoteDecision(outcome, alertID: alertID)
        return outcome
    }

    func end(_ alertID: UUID) {
        pilot?.end(alertID)
    }

    func applyProfile(_ value: PilotProfileDTO) {
        state.parent = value.parent.person
        state.guardians = value.guardians.map(\.person)
        if value.member.role == "guardian" {
            state.persona = .sinta
            if let me = value.guardians.first(where: { $0.id == value.member.id })?.person {
                state.guardians = [me] + state.guardians.filter { $0.id != me.id }
            }
        } else {
            state.persona = .ratna
        }
        state.pilotConnected = true
        state.pilotServerStatus = .reachable
        state.familySessionStatus = value.sessionStatus.flatMap(FamilySessionStatus.init(rawValue:))
        state.pilotRole = value.member.role
        state.pilotInviteCode = pilot?.inviteCode
        state.pilotInviteExpiresAt = pilot?.inviteExpiresAt
        state.pilotError = nil
        profile.persist()
    }

    func applyAlerts(_ values: [FamilyAlert]) {
        family.applyRemoteAlerts(values)
    }

    func applyHistory(_ values: [PilotHistoryRecordDTO]) {
        let remote = values.map { value in
            let level: RiskLevel
            switch value.presentation {
            case "danger": level = .danger
            case "review": level = .danger
            default: level = .safe
            }
            let unassessedReason: String?
            if value.presentation == "unassessed" {
                unassessedReason = (value.outcome == "no_speech"
                        ? "Tidak ada suara yang dapat dianalisis."
                        : "Analisis belum berhasil. Hasil panggilan ini belum tersedia.")
            } else {
                unassessedReason = nil
            }
            let isUnassessed = unassessedReason != nil
            return CallRecord(
                id: value.id,
                title: value.title,
                callerDetail: value.callerDetail,
                channel: value.channel.flatMap(CallChannel.init(rawValue:)) ?? .cellular,
                startedAt: value.startedAt,
                duration: value.durationSeconds,
                level: level,
                signals: isUnassessed ? [] : value.signals.compactMap(SignalKind.init(rawValue:)),
                evidence: isUnassessed ? [] : value.evidence.map(\.line),
                decision: value.decision?.decision,
                unassessedReason: unassessedReason
            )
        }
        let remoteIDs = Set(remote.map(\.id))
        let localOnly = state.pilotConnected ? [] : state.history.filter { !remoteIDs.contains($0.id) }
        state.history = (remote + localOnly).sorted { lhs, rhs in
            if lhs.startedAt == rhs.startedAt { return lhs.id.uuidString < rhs.id.uuidString }
            return lhs.startedAt > rhs.startedAt
        }
        profile.persist()
    }
}
