import Foundation
import Security

// MARK: - Persistent pilot identity

enum RambuServer {
    static let url = "https://rambu-api.sfatimah.com"
}

struct PilotCredentials: Codable, Sendable {
    let serverURL: String
    let familyID: String
    var member: PilotPersonDTO
    let accessToken: String
    var inviteCode: String?
    var inviteExpiresAt: Date? = nil
}

struct PilotCredentialStore: Sendable {
    private let service = "id.rambu.puck.pilot"
    private let account = "active-device"

    func load() -> PilotCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(PilotCredentials.self, from: data)
    }

    func save(_ value: PilotCredentials) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(identity as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var inserted = identity
            attributes.forEach { inserted[$0.key] = $0.value }
            SecItemAdd(inserted as CFDictionary, nil)
        }
    }

    func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Wire types

struct PilotPersonDTO: Codable, Sendable {
    let id: String
    let name: String
    let relation: String
    let role: String

    var person: Person {
        let palette: [UInt32] = [0x1E6E9E, 0x6347A8, 0xA23B72, 0x8A5A12]
        let stableIndex = id.utf8.reduce(0) { (result, byte) in (result + Int(byte)) % palette.count }
        let color = role == "parent" ? UInt32(0x006F63) : palette[stableIndex]
        let initial = name.split(separator: " ").last?.first.map { String($0).uppercased() } ?? "?"
        return Person(id: id, name: name, initial: initial, relation: relation, colorHex: color)
    }
}

struct PilotSessionDTO: Codable, Sendable {
    let familyID: String
    let member: PilotPersonDTO
    let accessToken: String
    let inviteCode: String?
    let inviteExpiresAt: Date?

    private enum CodingKeys: String, CodingKey {
        case familyID = "familyId"
        case member
        case accessToken
        case inviteCode
        case inviteExpiresAt
    }
}

struct PilotProfileDTO: Codable, Sendable {
    let familyID: String
    let member: PilotPersonDTO
    let parent: PilotPersonDTO
    let guardians: [PilotPersonDTO]
    var sessionStatus: String? = nil

    private enum CodingKeys: String, CodingKey {
        case familyID = "familyId"
        case member
        case parent
        case guardians
        case sessionStatus
    }
}

struct PilotInviteDTO: Codable, Sendable {
    let code: String
    let expiresAt: Date
}

struct PilotTranscriptLineDTO: Codable, Sendable {
    let id: Int
    let offset: TimeInterval?
    let speaker: String
    let text: String
    let flagged: [String]
    let signals: [String]

    init(_ line: TranscriptLine) {
        id = line.id
        offset = line.offset
        speaker = line.speaker.rawValue
        text = line.text
        flagged = line.flagged
        signals = line.signals.map(\.rawValue)
    }

    var line: TranscriptLine {
        TranscriptLine(
            id: id,
            offset: offset,
            speaker: Speaker(rawValue: speaker) ?? .unknown,
            text: text,
            flagged: flagged,
            signals: signals.compactMap(SignalKind.init(rawValue:))
        )
    }
}

struct PilotDecisionDTO: Codable, Sendable {
    let by: PilotPersonDTO
    let verdict: String
    let at: Date

    var decision: GuardianDecision {
        GuardianDecision(by: by.person, verdict: Verdict(rawValue: verdict) ?? .safe, at: at)
    }
}

struct PilotAlertDTO: Codable, Sendable {
    let id: UUID
    let parent: PilotPersonDTO
    let callerDetail: String
    let channel: String
    let startedAt: Date
    let raisedAt: Date
    let level: String
    let signals: [String]
    let evidence: [PilotTranscriptLineDTO]
    let recipients: [PilotPersonDTO]
    let decision: PilotDecisionDTO?
    let callEnded: Bool

    var alert: FamilyAlert {
        FamilyAlert(
            id: id,
            parent: parent.person,
            callerDetail: callerDetail,
            channel: CallChannel(rawValue: channel) ?? .cellular,
            startedAt: startedAt,
            raisedAt: raisedAt,
            level: .danger,
            signals: signals.compactMap(SignalKind.init(rawValue:)),
            evidence: evidence.map(\.line),
            recipients: recipients.map(\.person),
            decision: decision?.decision,
            callEnded: callEnded
        )
    }
}

struct PilotHistoryRecordDTO: Decodable, Sendable {
    let id: UUID
    let parent: PilotPersonDTO
    let title: String
    let callerDetail: String
    let channel: String?
    let startedAt: Date
    let endedAt: Date
    let durationSeconds: TimeInterval
    let outcome: String
    let presentation: String
    let signals: [String]
    let evidence: [PilotTranscriptLineDTO]
    let decision: PilotDecisionDTO?
    let failure: ProtectionFailureDTO?
}

private struct PilotAlertRequest: Encodable {
    let id: UUID
    let callerDetail: String
    let channel: String
    let startedAt: Date
    let raisedAt: Date
    let level: String
    let signals: [String]
    let evidence: [PilotTranscriptLineDTO]

    init(_ alert: FamilyAlert) {
        id = alert.id
        callerDetail = alert.callerDetail
        channel = alert.channel.rawValue
        startedAt = alert.startedAt
        raisedAt = alert.raisedAt
        level = alert.level == .danger ? "danger" : "review"
        signals = alert.signals.map(\.rawValue)
        evidence = alert.evidence.map(PilotTranscriptLineDTO.init)
    }
}

struct PilotDecisionResultDTO: Codable, Sendable {
    let accepted: Bool
    let decision: PilotDecisionDTO
}

private struct CreateFamilyBody: Encodable { let parentName: String }
private struct JoinFamilyBody: Encodable { let code: String; let name: String; let relation: String }
private struct DecisionBody: Encodable { let verdict: String }
private struct PushTokenBody: Encodable { let token: String; let environment: String }
private struct PuckNameBody: Encodable { let displayName: String }
struct PuckPairingDTO: Codable, Sendable { let accessToken: String }
private struct APIMessage: Decodable { let detail: String }

enum PilotAPIError: LocalizedError {
    case invalidServerURL
    case invalidResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidServerURL: "Alamat server tidak valid."
        case .invalidResponse: "Belum dapat menerima data keluarga. Coba lagi."
        case .server(let message):
            switch message {
            case "Kode undangan harus 6 angka.": "Masukkan kode undangan 6 angka."
            case "Kode undangan tidak ditemukan.": "Kode tidak ditemukan. Periksa kembali kode dari orang tua."
            case "Kode undangan sudah kedaluwarsa.": "Kode sudah kedaluwarsa. Minta orang tua membuat kode baru."
            case "Token perangkat tidak valid.", "Token perangkat diperlukan.": "Akses keluarga sudah tidak berlaku. Hubungkan keluarga kembali."
            case "Keluarga ini sudah memiliki terlalu banyak pengawas.": "Jumlah pendamping sudah mencapai batas."
            default: "Belum dapat terhubung ke server. Coba lagi."
            }
        }
    }

    static func displayMessage(for error: Error) -> String {
        if let error = error as? PilotAPIError { return error.localizedDescription }
        return "Belum dapat terhubung ke server. Periksa koneksi internet lalu coba lagi."
    }
}

struct PilotAPI: Sendable {
    let baseURL: URL
    let session: any HTTPDataSession

    init(serverURL: String, session: any HTTPDataSession = URLSession.shared) throws {
        let value = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value), ["http", "https"].contains(url.scheme), url.host != nil else {
            throw PilotAPIError.invalidServerURL
        }
        baseURL = url
        self.session = session
    }

    func createFamily(parentName: String) async throws -> PilotSessionDTO {
        try await request("api/pilot/families", method: "POST", body: CreateFamilyBody(parentName: parentName))
    }

    func joinFamily(code: String, name: String, relation: String) async throws -> PilotSessionDTO {
        try await request("api/pilot/families/join", method: "POST",
                          body: JoinFamilyBody(code: code, name: name, relation: relation))
    }

    func profile(token: String) async throws -> PilotProfileDTO {
        try await request("api/pilot/profile", token: token, body: Optional<String>.none)
    }

    func renewInvite(token: String) async throws -> PilotInviteDTO {
        try await request("api/pilot/invites", method: "POST", token: token, body: Optional<String>.none)
    }

    func pairPuck(token: String) async throws -> PuckPairingDTO {
        try await request("api/pilot/pucks", method: "POST", token: token, body: PuckNameBody(displayName: "Rambu Puck"))
    }

    func alerts(token: String) async throws -> [PilotAlertDTO] {
        try await request("api/pilot/alerts", token: token, body: Optional<String>.none)
    }

    func history(token: String) async throws -> [PilotHistoryRecordDTO] {
        try await request("api/pilot/history", token: token, body: Optional<String>.none)
    }

    func publish(_ alert: FamilyAlert, token: String) async throws -> PilotAlertDTO {
        try await request("api/pilot/alerts", method: "POST", token: token, body: PilotAlertRequest(alert))
    }

    func decide(_ verdict: Verdict, alertID: UUID, token: String) async throws -> PilotDecisionResultDTO {
        try await request("api/pilot/alerts/\(alertID)/decision", method: "POST", token: token,
                          body: DecisionBody(verdict: verdict.rawValue), acceptsConflict: true)
    }

    func end(alertID: UUID, token: String) async throws -> PilotAlertDTO {
        try await request("api/pilot/alerts/\(alertID)/end", method: "POST", token: token,
                          body: Optional<String>.none)
    }

    func registerPushToken(_ pushToken: String, environment: String, token: String) async throws {
        let _: EmptyResponse = try await request("api/pilot/push-token", method: "PUT", token: token,
                                                 body: PushTokenBody(token: pushToken, environment: environment))
    }

    private func request<Response: Decodable, Body: Encodable>(
        _ path: String,
        method: String = "GET",
        token: String? = nil,
        body: Body? = nil,
        acceptsConflict: Bool = false
    ) async throws -> Response {
        var request = URLRequest(url: path.split(separator: "/").reduce(baseURL) { $0.appending(path: String($1)) })
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try Self.encoder.encode(body)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw PilotAPIError.invalidResponse }
        if !(200..<300).contains(http.statusCode) && !(acceptsConflict && http.statusCode == 409) {
            let message = (try? Self.decoder.decode(APIMessage.self, from: data))?.detail
            throw PilotAPIError.server(message ?? "Server mengembalikan status \(http.statusCode).")
        }
        if data.isEmpty, let empty = EmptyResponse() as? Response { return empty }
        do {
            return try Self.decoder.decode(Response.self, from: data)
        } catch {
            throw PilotAPIError.invalidResponse
        }
    }

    private static let encoder: JSONEncoder = {
        let value = JSONEncoder()
        value.keyEncodingStrategy = .convertToSnakeCase
        value.dateEncodingStrategy = .iso8601
        return value
    }()

    private static let decoder: JSONDecoder = {
        let value = JSONDecoder()
        value.keyDecodingStrategy = .convertFromSnakeCase
        value.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let standard = ISO8601DateFormatter()
            guard let date = fractional.date(from: text) ?? standard.date(from: text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Tanggal ISO-8601 tidak valid")
            }
            return date
        }
        return value
    }()

    private struct EmptyResponse: Decodable {}
}

// MARK: - App-facing sync

@MainActor
final class PilotSync {
    var onAlerts: (([FamilyAlert]) -> Void)?
    var onProfile: ((PilotProfileDTO) -> Void)?
    var onHistory: (([PilotHistoryRecordDTO]) -> Void)?
    var onError: ((String) -> Void)?
    var onServerStatus: ((PilotServerStatus) -> Void)?

    private(set) var credentials: PilotCredentials?
    private let credentialStore: PilotCredentialStore
    private let session: any HTTPDataSession
    private var pollTask: Task<Void, Never>?
    private var operationTask: Task<Void, Never>?
    private var pushToken: String?
    private var connectionGeneration = 0

    init(
        credentialStore: PilotCredentialStore = PilotCredentialStore(),
        session: any HTTPDataSession = URLSession.shared,
        initialCredentials: PilotCredentials? = nil
    ) {
        self.credentialStore = credentialStore
        self.session = session
        if let initialCredentials {
            credentials = initialCredentials
        } else if let saved = credentialStore.load(), saved.serverURL != RambuServer.url {
            let moved = PilotCredentials(
                serverURL: RambuServer.url,
                familyID: saved.familyID,
                member: saved.member,
                accessToken: saved.accessToken,
                inviteCode: saved.inviteCode,
                inviteExpiresAt: saved.inviteExpiresAt
            )
            credentialStore.save(moved)
            credentials = moved
        } else {
            credentials = credentialStore.load()
        }
        RambuAppDelegate.onPushToken = { [weak self] token in self?.receivePushToken(token) }
        if let token = RambuAppDelegate.latestPushToken { receivePushToken(token) }
    }

    var isConnected: Bool { credentials != nil }
    var inviteCode: String? { credentials?.inviteCode }
    var inviteExpiresAt: Date? { credentials?.inviteExpiresAt }
    var serverURL: String { credentials?.serverURL ?? RambuServer.url }

    func start() {
        guard credentials != nil, pollTask == nil else { return }
        pollTask = Task { [weak self] in
            await self?.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { break }
                await self?.refresh(quietly: true)
            }
        }
    }

    func createFamily(serverURL: String, parentName: String) async throws -> String {
        let api = try PilotAPI(serverURL: serverURL, session: session)
        let session = try await api.createFamily(parentName: parentName)
        configure(serverURL: serverURL, session: session)
        await refresh()
        return session.inviteCode ?? ""
    }

    func joinFamily(serverURL: String, code: String, name: String, relation: String) async throws {
        let api = try PilotAPI(serverURL: serverURL, session: session)
        let session = try await api.joinFamily(code: code, name: name, relation: relation)
        configure(serverURL: serverURL, session: session)
        await refresh()
    }

    func renewInvite() async throws -> String {
        guard var credentials else { throw PilotAPIError.server("Hubungkan server terlebih dahulu.") }
        let invite = try await PilotAPI(serverURL: credentials.serverURL, session: session)
            .renewInvite(token: credentials.accessToken)
        credentials.inviteCode = invite.code
        credentials.inviteExpiresAt = invite.expiresAt
        self.credentials = credentials
        credentialStore.save(credentials)
        return invite.code
    }

    func pairPuck() async throws -> String {
        guard let credentials else { throw PilotAPIError.server("Hubungkan keluarga terlebih dahulu.") }
        return try await PilotAPI(serverURL: credentials.serverURL, session: session)
            .pairPuck(token: credentials.accessToken).accessToken
    }

    func disconnect() {
        connectionGeneration += 1
        pollTask?.cancel()
        pollTask = nil
        operationTask?.cancel()
        operationTask = nil
        credentials = nil
        credentialStore.clear()
        onServerStatus?(.unknown)
    }

    func publish(_ alert: FamilyAlert) {
        guard let credentials, credentials.member.role == "parent" else { return }
        enqueue { [weak self] in
            guard let self else { return }
            do {
                _ = try await PilotAPI(serverURL: credentials.serverURL, session: self.session)
                    .publish(alert, token: credentials.accessToken)
            } catch { await self.report(error) }
        }
    }

    func submit(_ verdict: Verdict, alertID: UUID) async -> DecisionOutcome? {
        guard let credentials, credentials.member.role == "guardian" else { return nil }
        do {
            let result = try await PilotAPI(serverURL: credentials.serverURL, session: session)
                .decide(verdict, alertID: alertID, token: credentials.accessToken)
            await refreshAlerts(quietly: true)
            return result.accepted ? .accepted(result.decision.decision) : .alreadyDecided(result.decision.decision)
        } catch {
            onError?(PilotAPIError.displayMessage(for: error))
            return nil
        }
    }

    func end(_ alertID: UUID) {
        guard let credentials, credentials.member.role == "parent" else { return }
        enqueue { [weak self] in
            guard let self else { return }
            do {
                _ = try await PilotAPI(serverURL: credentials.serverURL, session: self.session)
                    .end(alertID: alertID, token: credentials.accessToken)
            } catch { await self.report(error) }
        }
    }

    func refresh() async {
        await refresh(quietly: false)
    }

    private func refresh(quietly: Bool) async {
        guard let credentials else { return }
        let generation = connectionGeneration
        do {
            let api = try PilotAPI(serverURL: credentials.serverURL, session: session)
            async let profile = api.profile(token: credentials.accessToken)
            async let alerts = api.alerts(token: credentials.accessToken)
            async let history = api.history(token: credentials.accessToken)
            let (profileValue, alertValues, historyValues) = try await (profile, alerts, history)
            guard generation == connectionGeneration, !Task.isCancelled else { return }
            onServerStatus?(.reachable)
            onProfile?(profileValue)
            onAlerts?(alertValues.map(\.alert))
            onHistory?(historyValues)
        } catch {
            guard generation == connectionGeneration, !Task.isCancelled else { return }
            onServerStatus?(.unavailable)
            onError?("Keluarga belum dapat diperbarui. \(PilotAPIError.displayMessage(for: error))")
        }
    }

    private func refreshAlerts(quietly: Bool) async {
        guard let credentials else { return }
        let generation = connectionGeneration
        do {
            let values = try await PilotAPI(serverURL: credentials.serverURL, session: session)
                .alerts(token: credentials.accessToken)
            guard generation == connectionGeneration, !Task.isCancelled else { return }
            onAlerts?(values.map(\.alert))
        } catch {
            guard generation == connectionGeneration, !Task.isCancelled else { return }
            if !quietly { onError?(PilotAPIError.displayMessage(for: error)) }
        }
    }

    private func configure(serverURL: String, session: PilotSessionDTO) {
        connectionGeneration += 1
        let value = PilotCredentials(
            serverURL: serverURL.trimmingCharacters(in: .whitespacesAndNewlines),
            familyID: session.familyID,
            member: session.member,
            accessToken: session.accessToken,
            inviteCode: session.inviteCode,
            inviteExpiresAt: session.inviteExpiresAt
        )
        credentials = value
        credentialStore.save(value)
        pollTask?.cancel()
        pollTask = nil
        start()
        registerPushTokenIfPossible()
    }

    private func enqueue(_ operation: @escaping @Sendable () async -> Void) {
        let previous = operationTask
        operationTask = Task {
            await previous?.value
            guard !Task.isCancelled else { return }
            await operation()
        }
    }

    private func report(_ error: Error) {
        onError?(PilotAPIError.displayMessage(for: error))
    }

    private func receivePushToken(_ token: String) {
        pushToken = token
        registerPushTokenIfPossible()
    }

    private func registerPushTokenIfPossible() {
        guard let credentials, let pushToken else { return }
        #if DEBUG
        let environment = "sandbox"
        #else
        let environment = "production"
        #endif
        Task { [weak self] in
            guard let self else { return }
            do {
                try await PilotAPI(serverURL: credentials.serverURL, session: self.session)
                    .registerPushToken(pushToken, environment: environment, token: credentials.accessToken)
            } catch {
                self.report(error)
            }
        }
    }
}
