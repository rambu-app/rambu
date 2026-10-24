import Foundation
import Testing
@testable import RambuPuck

private actor PilotHTTPStub: HTTPDataSession {
    private var responses: [String: Data]
    private var requestedPaths: [String] = []
    private var requestBodies: [String: Data] = [:]
    private var requestMethods: [String: String] = [:]

    init(responses: [String: String]) {
        self.responses = responses.mapValues { Data($0.utf8) }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let path = request.url?.path ?? ""
        requestedPaths.append(path)
        requestBodies[path] = request.httpBody
        requestMethods[path] = request.httpMethod
        guard let data = responses[path], let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
              ) else {
            throw URLError(.badServerResponse)
        }
        return (data, response)
    }

    func paths() -> [String] { requestedPaths }
    func body(for path: String) -> Data? { requestBodies[path] }
    func method(for path: String) -> String? { requestMethods[path] }
    func respond(_ body: String, for path: String) { responses[path] = Data(body.utf8) }
}

private actor GatedPilotHTTPStub: HTTPDataSession {
    private let base: any HTTPDataSession
    private let fail: Bool
    private var gate: CheckedContinuation<Void, Never>?
    var isWaiting = false

    init(base: any HTTPDataSession, fail: Bool) { self.base = base; self.fail = fail }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        if request.url?.path == "/api/pilot/profile" {
            isWaiting = true
            await withCheckedContinuation { gate = $0 }
            if fail { throw URLError(.notConnectedToInternet) }
        }
        return try await base.data(for: request)
    }

    func release() { gate?.resume(); gate = nil }
}

@MainActor
@Suite(.serialized)
struct PilotViewModelTests {
    @Test("A late refresh cannot restore a departed family's profile or connection status")
    func ignoresRefreshAfterDisconnect() async throws {
        let store = PilotCredentialStore()
        let previous = store.load()
        defer { if let previous { store.save(previous) } else { store.clear() } }
        for fail in [false, true] {
            let base = PilotHTTPStub(responses: ["/api/pilot/profile": Self.profileJSON,
                                                  "/api/pilot/alerts": "[]", "/api/pilot/history": "[]"])
            let transport = GatedPilotHTTPStub(base: base, fail: fail)
            let sync = PilotSync(session: transport, initialCredentials: Self.credentials)
            var profiles = 0
            var statuses: [PilotServerStatus] = []
            var errors: [String] = []
            sync.onProfile = { _ in profiles += 1 }
            sync.onServerStatus = { statuses.append($0) }
            sync.onError = { errors.append($0) }
            let request = Task { await sync.refresh() }
            for _ in 0..<100 {
                if await transport.isWaiting { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(await transport.isWaiting)
            sync.disconnect()
            await transport.release()
            await request.value
            #expect(profiles == 0)
            #expect(statuses == [.unknown])
            #expect(errors.isEmpty)
            #expect(!sync.isConnected)
        }
    }
    @Test("A failed background refresh reports unavailable without losing family membership")
    func backgroundRefreshReportsFailureAndRecovers() async throws {
        let store = PilotCredentialStore()
        let previous = store.load()
        defer { if let previous { store.save(previous) } else { store.clear() } }
        let stub = PilotHTTPStub(responses: ["/api/pilot/profile": Self.profileJSON,
                                              "/api/pilot/alerts": "[]", "/api/pilot/history": "[]"])
        let sync = PilotSync(session: stub, initialCredentials: Self.credentials)
        var updates = 0
        var error: String?
        var serverStatus: PilotServerStatus = .unknown
        sync.onProfile = { _ in updates += 1 }
        sync.onError = { error = $0 }
        sync.onServerStatus = { serverStatus = $0 }
        sync.start()
        defer { sync.disconnect() }
        for _ in 0..<100 where updates == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(updates > 0)
        #expect(serverStatus == .reachable)
        await stub.respond("invalid response", for: "/api/pilot/history")
        for _ in 0..<250 where error == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(error != nil)
        #expect(serverStatus == .unavailable)
        #expect(sync.isConnected)
        await stub.respond("[]", for: "/api/pilot/history")
        let before = updates
        await sync.refresh()
        #expect(updates == before + 1)
        #expect(serverStatus == .reachable)
    }
    @Test("Profile decoding retains authoritative session status and supports older servers")
    func profileRetainsSessionStatus() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let json = Self.profileJSON.replacingOccurrences(of: "\"family_id\":", with: "\"session_status\":\"listening\",\"family_id\":")
        let profile = try decoder.decode(PilotProfileDTO.self, from: Data(json.utf8))
        let encoded = try JSONEncoder().encode(profile)
        let values = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(values["sessionStatus"] as? String == "listening")
        let (state, pilot) = makePilot(persona: .sinta)
        #expect(state.session == nil)
        pilot.applyProfile(profile)
        #expect(state.guardianSessionStatus == .listening)
        state.pilotServerStatus = .unavailable
        #expect(state.guardianSessionStatus == .unknown)
        #expect(state.pilotConnected)
        for raw in ["idle", "waiting_for_puck", "finishing"] {
            var next = profile
            next.sessionStatus = raw
            pilot.applyProfile(next)
            #expect(state.guardianSessionStatus.rawValue == raw)
        }
        let oldProfile = try decoder.decode(PilotProfileDTO.self, from: Data(Self.profileJSON.utf8))
        pilot.applyProfile(oldProfile)
        #expect(state.guardianSessionStatus == .unknown)
        var unsupported = profile
        unsupported.sessionStatus = "unsupported"
        pilot.applyProfile(unsupported)
        #expect(state.guardianSessionStatus == .unknown)
    }

    @Test("Evidence without audio timing decodes without losing older saved excerpts")
    func nullableEvidenceTimingIsBackwardCompatible() throws {
        let decoder = JSONDecoder()
        for suffix in ["", ",\"offset\":null", ",\"offset\":12"] {
            let json = "{\"id\":0,\"speaker\":\"unknown\",\"text\":\"Berikan OTP\",\"flagged\":[\"OTP\"],\"signals\":[\"secretCode\"]\(suffix)}"
            let line = try decoder.decode(PilotTranscriptLineDTO.self, from: Data(json.utf8)).line
            #expect(line.text == "Berikan OTP")
            #expect(line.offset == (suffix.contains("12") ? 12 : nil))
        }
        let json = #"{"id":0,"speaker":"unknown","text":"Berikan OTP","flagged":[],"signals":[]}"#
        let saved = try decoder.decode(TranscriptLine.self, from: Data(json.utf8))
        #expect(saved.offset == nil)
        #expect(try decoder.decode(TranscriptLine.self, from: JSONEncoder().encode(saved)) == saved)
    }

    @Test("A family member's saved contact number reaches the dialable app profile")
    func familyProfileRetainsPhoneNumber() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let member = try decoder.decode(PilotPersonDTO.self, from: Data(#"{"id":"parent-1","name":"Ibu","relation":"Ibu","role":"parent","phone_number":"+6281234567890"}"#.utf8))
        let stored = try JSONEncoder().encode(member.person)
        let values = try #require(JSONSerialization.jsonObject(with: stored) as? [String: Any])
        #expect(values["phoneNumber"] as? String == "+6281234567890")
        #expect(member.person.telephoneURL?.absoluteString == "tel:+6281234567890")
        #expect(member.person.renamed("Ibu Baru").telephoneURL?.absoluteString == "tel:+6281234567890")
    }

    @Test("Call URLs contain only valid international numbers, never dummy or control characters")
    func callURLValidationAndLegacyProfiles() throws {
        for input in ["", "112", "tel:123", "+62812;123456", "+62812#123456", "+" + String(repeating: "1", count: 16)] {
            #expect(PhoneNumber.normalized(input) == nil)
        }
        #expect(PhoneNumber.normalized("0812-3456-7890") == "+6281234567890")
        #expect(PhoneNumber.normalized("+1 (415) 555-0123") == "+14155550123")
        #expect(Person.ratna.telephoneURL == nil)
        let legacy = try JSONDecoder().decode(Person.self, from: JSONEncoder().encode(Person.ratna))
        #expect(legacy.telephoneURL == nil)
    }

    @Test("Updating the own contact sends PUT and retains server membership")
    func syncSavesOwnNumberAndCanClearIt() async throws {
        let credentialStore = PilotCredentialStore()
        let previous = credentialStore.load()
        defer { if let previous { credentialStore.save(previous) } else { credentialStore.clear() } }
        let response = Self.profileJSON.replacingOccurrences(of: "\"role\": \"guardian\"", with: "\"role\": \"guardian\", \"phone_number\": \"+6281234567890\"")
        let stub = PilotHTTPStub(responses: ["/api/pilot/profile": response])
        let sync = PilotSync(session: stub, initialCredentials: Self.credentials)
        let updated = try await sync.updatePhoneNumber("+6281234567890")
        #expect(updated.member.phoneNumber == "+6281234567890")
        #expect(sync.credentials?.member.phoneNumber == "+6281234567890")
        #expect(await stub.method(for: "/api/pilot/profile") == "PUT")
        let first = try #require(await stub.body(for: "/api/pilot/profile"))
        #expect((try JSONSerialization.jsonObject(with: first) as? [String: String])?["phone_number"] == "+6281234567890")
        _ = try await sync.updatePhoneNumber("")
        let cleared = try #require(await stub.body(for: "/api/pilot/profile"))
        #expect((try JSONSerialization.jsonObject(with: cleared) as? [String: String])?["phone_number"] == "")
    }

    @Test("An empty server history removes cached pilot call records after a reset")
    func emptyServerHistoryClearsConnectedCache() {
        let (state, pilot) = makePilot()
        state.pilotConnected = true
        state.history = CallRecord.seed()
        #expect(!state.history.isEmpty)
        pilot.applyHistory([])
        #expect(state.history.isEmpty)
    }

    @Test("Infrastructure diagnostics are not exposed as family error messages")
    func hidesInfrastructureDiagnostics() {
        let diagnostic = "The origin web server returned an invalid response to Cloudflare. private-token"
        let message = PilotAPIError.server(diagnostic).localizedDescription
        #expect(!message.contains("Cloudflare"))
        #expect(!message.contains("private-token"))
        #expect(message.contains("Coba lagi"))
    }

    @Test("A successfully refreshed profile clears the previous error without losing membership")
    func successfulProfileClearsOldError() throws {
        let (state, pilot) = makePilot()
        state.pilotError = "Perbarui keluarga gagal"
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        pilot.applyProfile(try decoder.decode(PilotProfileDTO.self, from: Data(Self.profileJSON.utf8)))
        #expect(state.pilotError == nil)
        #expect(state.pilotConnected)
        #expect(state.guardians.first?.name == "Richard")
    }

    @Test("Renewal retains the server expiry with the invitation in stored credentials")
    func renewalKeepsExpiry() async throws {
        let store = PilotCredentialStore()
        let previous = store.load()
        defer { if let previous { store.save(previous) } else { store.clear() } }
        let stub = PilotHTTPStub(responses: [
            "/api/pilot/invites": #"{"code":"715204","expires_at":"2026-10-07T14:10:00Z"}"#,
        ])
        let sync = PilotSync(session: stub, initialCredentials: Self.credentials)
        _ = try await sync.renewInvite()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let stored = try #require(store.load())
        let data = try encoder.encode(stored)
        let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(payload["inviteCode"] as? String == "715204")
        #expect(payload["inviteExpiresAt"] as? String == "2026-10-07T14:10:00Z")
    }
    @Test("Parent-generated invitation is sent with the child's own identity")
    func createsAndJoinsWithServerInvitation() async throws {
        let stub = PilotHTTPStub(responses: [
            "/api/pilot/families": #"{"family_id":"family-1","member":{"id":"parent-1","name":"Bu Sri","relation":"Orang tua","role":"parent"},"access_token":"test-parent-token","invite_code":"715204","invite_expires_at":null}"#,
            "/api/pilot/families/join": #"{"family_id":"family-1","member":{"id":"guardian-1","name":"Dewi","relation":"Anak","role":"guardian"},"access_token":"test-guardian-token","invite_code":null,"invite_expires_at":null}"#,
        ])
        let api = try PilotAPI(serverURL: "https://rambu.test", session: stub)
        let parent = try await api.createFamily(parentName: "Bu Sri")
        let child = try await api.joinFamily(code: try #require(parent.inviteCode), name: "Dewi", relation: "Anak")
        #expect(parent.familyID == child.familyID)
        #expect(child.member.role == "guardian")
        let body = try #require(await stub.body(for: "/api/pilot/families/join"))
        let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(payload["code"] == "715204")
        #expect(payload["name"] == "Dewi")
    }
    @Test("Respons buat keluarga membaca family_id dari backend")
    func decodesCreateFamilyResponse() throws {
        let data = Data(#"""
        {
          "family_id": "family-1",
          "member": {"id": "parent-1", "name": "Ratna", "relation": "Orang tua", "role": "parent"},
          "access_token": "token-1",
          "invite_code": "123456",
          "invite_expires_at": null
        }
        """#.utf8)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let session = try decoder.decode(PilotSessionDTO.self, from: data)

        #expect(session.familyID == "family-1")
        #expect(session.inviteCode == "123456")
    }

    @Test("Respons profil keluarga membaca family_id dari backend")
    func decodesFamilyProfileResponse() throws {
        let data = Data(#"""
        {
          "family_id": "family-1",
          "member": {"id": "parent-1", "name": "Ratna", "relation": "Orang tua", "role": "parent"},
          "parent": {"id": "parent-1", "name": "Ratna", "relation": "Orang tua", "role": "parent"},
          "guardians": []
        }
        """#.utf8)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let profile = try decoder.decode(PilotProfileDTO.self, from: data)

        #expect(profile.familyID == "family-1")
    }

    @Test("Riwayat pilot membaca semua hasil penilaian backend")
    func decodesEveryHistoryPresentation() throws {
        let data = Data(#"""
        [
          {
            "id": "10000000-0000-0000-0000-000000000001",
            "parent": {"id": "parent-1", "name": "Ratna", "relation": "Orang tua", "role": "parent"},
            "title": "Aman", "caller_detail": "Nomor tidak tersedia", "channel": "cellular",
            "started_at": "2026-10-03T10:00:00Z", "ended_at": "2026-10-03T10:00:45Z",
            "duration_seconds": 45, "outcome": "analyzed", "presentation": "safe",
            "signals": [], "evidence": [], "decision": null, "failure": null
          },
          {
            "id": "10000000-0000-0000-0000-000000000002",
            "parent": {"id": "parent-1", "name": "Ratna", "relation": "Orang tua", "role": "parent"},
            "title": "Waspada", "caller_detail": "+62 812-••••-4417", "channel": "whatsapp",
            "started_at": "2026-10-03T10:01:00Z", "ended_at": "2026-10-03T10:01:45Z",
            "duration_seconds": 45, "outcome": "analyzed", "presentation": "review",
            "signals": ["impersonation"], "evidence": [], "decision": null, "failure": null
          },
          {
            "id": "10000000-0000-0000-0000-000000000003",
            "parent": {"id": "parent-1", "name": "Ratna", "relation": "Orang tua", "role": "parent"},
            "title": "Bahaya", "caller_detail": "+62 812-••••-4417", "channel": "cellular",
            "started_at": "2026-10-03T10:02:00Z", "ended_at": "2026-10-03T10:02:45Z",
            "duration_seconds": 45, "outcome": "analyzed", "presentation": "danger",
            "signals": ["secretCode", "remoteApp"],
            "evidence": [{"id": 0, "offset": 0, "speaker": "unknown", "text": "Berikan OTP", "flagged": ["OTP"], "signals": ["secretCode"]}],
            "decision": null, "failure": null
          },
          {
            "id": "10000000-0000-0000-0000-000000000004",
            "parent": {"id": "parent-1", "name": "Ratna", "relation": "Orang tua", "role": "parent"},
            "title": "Tidak terdengar", "caller_detail": "Nomor tidak tersedia", "channel": null,
            "started_at": "2026-10-03T10:03:00Z", "ended_at": "2026-10-03T10:03:45Z",
            "duration_seconds": 45, "outcome": "no_speech", "presentation": "unassessed",
            "signals": [], "evidence": [], "decision": null, "failure": null
          },
          {
            "id": "10000000-0000-0000-0000-000000000005",
            "parent": {"id": "parent-1", "name": "Ratna", "relation": "Orang tua", "role": "parent"},
            "title": "Gagal", "caller_detail": "Nomor tidak tersedia", "channel": "cellular",
            "started_at": "2026-10-03T10:04:00Z", "ended_at": "2026-10-03T10:04:45Z",
            "duration_seconds": 45, "outcome": "error", "presentation": "unassessed",
            "signals": [], "evidence": [], "decision": null,
            "failure": {"code": "analysis_timeout", "message": "Analisis panggilan gagal."}
          }
        ]
        """#.utf8)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601

        let records = try decoder.decode([PilotHistoryRecordDTO].self, from: data)

        #expect(records.map(\.presentation) == ["safe", "review", "danger", "unassessed", "unassessed"])
        #expect(records.map(\.outcome) == ["analyzed", "analyzed", "analyzed", "no_speech", "error"])
        #expect(records[2].signals == ["secretCode", "remoteApp"])
        #expect(records[2].evidence[0].line.signals == [.secretCode])
        #expect(records[4].failure?.code == "analysis_timeout")
    }

    @Test("Refresh menerapkan profil, alert, dan riwayat secara atomik")
    func testRefreshFetchesProfileAlertsAndHistoryBeforeCallbacks() async {
        let stub = PilotHTTPStub(responses: [
            "/api/pilot/profile": Self.profileJSON,
            "/api/pilot/alerts": "[]",
            "/api/pilot/history": "[]",
        ])
        let sync = PilotSync(session: stub, initialCredentials: Self.credentials)
        var callbacks: [String] = []
        sync.onProfile = { _ in callbacks.append("profile") }
        sync.onAlerts = { _ in callbacks.append("alerts") }
        sync.onHistory = { _ in callbacks.append("history") }

        await sync.refresh()

        #expect(callbacks == ["profile", "alerts", "history"])
        #expect(Set(await stub.paths()) == [
            "/api/pilot/profile", "/api/pilot/alerts", "/api/pilot/history",
        ])
    }

    @Test("Riwayat rusak tidak menerapkan sebagian hasil refresh")
    func testRefreshIsAtomicWhenHistoryDecodingFails() async {
        let stub = PilotHTTPStub(responses: [
            "/api/pilot/profile": Self.profileJSON,
            "/api/pilot/alerts": "[]",
            "/api/pilot/history": #"[{"id":"not-a-uuid"}]"#,
        ])
        let sync = PilotSync(session: stub, initialCredentials: Self.credentials)
        var callbackCount = 0
        var visibleHistory = ["existing-call"]
        var receivedError: String?
        sync.onProfile = { _ in callbackCount += 1 }
        sync.onAlerts = { _ in callbackCount += 1 }
        sync.onHistory = { records in
            callbackCount += 1
            visibleHistory = records.map(\.title)
        }
        sync.onError = { receivedError = $0 }

        await sync.refresh()

        #expect(callbackCount == 0)
        #expect(visibleHistory == ["existing-call"])
        #expect(receivedError != nil)
    }

    private static let credentials = PilotCredentials(
        serverURL: "https://rambu.test",
        familyID: "family-1",
        member: PilotPersonDTO(id: "guardian-1", name: "Richard", relation: "Anak", role: "guardian"),
        accessToken: "test-token",
        inviteCode: nil
    )

    private static let profileJSON = #"""
    {
      "family_id": "family-1",
      "member": {"id": "guardian-1", "name": "Richard", "relation": "Anak", "role": "guardian"},
      "parent": {"id": "parent-1", "name": "Ratna", "relation": "Orang tua", "role": "parent"},
      "guardians": [{"id": "guardian-1", "name": "Richard", "relation": "Anak", "role": "guardian"}]
    }
    """#

    private func makePilot(
        persona: Persona = .ratna,
        store: LocalStore? = nil
    ) -> (AppState, PilotViewModel) {
        let state = AppState(persona: persona, onboardingComplete: true)
        let profile = ProfileViewModel(
            state: state,
            notifier: RambuNotifier(enabled: false),
            narrator: Narrator(enabled: false),
            network: NetworkMonitor(),
            store: store
        )
        let family = FamilyViewModel(
            state: state,
            relay: LocalFamilyRelay(),
            feedback: LocalDetectionFeedback(),
            liveActivity: CallLiveActivity(enabled: false),
            profile: profile,
            present: profile.present
        )
        return (state, PilotViewModel(state: state, pilot: nil, family: family, profile: profile))
    }

    private func historyDTO(
        id: UUID = UUID(),
        title: String = "Riwayat server",
        startedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        presentation: String = "danger",
        decision: PilotDecisionDTO? = nil
    ) -> PilotHistoryRecordDTO {
        PilotHistoryRecordDTO(
            id: id,
            parent: PilotPersonDTO(id: "parent", name: "Bu Sri", relation: "Ibu", role: "parent"),
            title: title,
            callerDetail: "+62 812-••••-4417",
            channel: "cellular",
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(45),
            durationSeconds: 45,
            outcome: "analyzed",
            presentation: presentation,
            signals: presentation == "safe" ? [] : ["secretCode"],
            evidence: [],
            decision: decision,
            failure: nil
        )
    }

    @Test("Riwayat server mengganti versi lokal dan mempertahankan rekaman offline")
    func testRemoteHistoryReplacesMatchingLocalRecordAndKeepsOfflineRecords() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rambu-pilot-history-\(UUID()).json")
        let store = LocalStore(url: url)
        defer { store.clear() }
        let (state, pilot) = makePilot(store: store)
        let matchingID = UUID()
        let offlineID = UUID()
        state.history = [
            CallRecord(
                id: matchingID, title: "Versi lokal", callerDetail: "Lokal", channel: .cellular,
                startedAt: Date(timeIntervalSince1970: 10), duration: 1, level: .safe,
                signals: [], evidence: [], decision: nil
            ),
            CallRecord(
                id: offlineID, title: "Offline", callerDetail: "Offline", channel: .cellular,
                startedAt: Date(timeIntervalSince1970: 20), duration: 2, level: .review,
                signals: [.urgency], evidence: [], decision: nil
            ),
        ]

        pilot.applyHistory([historyDTO(id: matchingID, title: "Versi server")])

        #expect(state.history.map(\.id) == [matchingID, offlineID])
        #expect(state.history.first?.title == "Versi server")
        #expect(state.history.filter { $0.id == matchingID }.count == 1)
        #expect(try #require(store.load()).history.map(\.id) == [matchingID, offlineID])
    }

    @Test("Orang tua dan pengawas menerapkan riwayat server yang sama")
    func testParentAndGuardianApplyIdenticalRemoteHistory() {
        let (parentState, parentPilot) = makePilot(persona: .ratna)
        let (guardianState, guardianPilot) = makePilot(persona: .sinta)
        parentState.history = []
        guardianState.history = []
        let records = [
            historyDTO(title: "Terbaru", startedAt: Date(timeIntervalSince1970: 200)),
            historyDTO(title: "Lebih lama", startedAt: Date(timeIntervalSince1970: 100), presentation: "safe"),
        ]

        parentPilot.applyHistory(records)
        guardianPilot.applyHistory(records)

        #expect(parentState.history == guardianState.history)
        #expect(parentState.history.map(\.title) == ["Terbaru", "Lebih lama"])
    }

    @Test("Keputusan server memperbarui riwayat yang sudah ada")
    func testRemoteDecisionUpdatesExistingHistory() throws {
        let (state, pilot) = makePilot()
        let id = UUID()
        state.history = [CallRecord(
            id: id, title: "Lokal", callerDetail: "Nomor", channel: .cellular,
            startedAt: .now, duration: 4, level: .danger,
            signals: [.secretCode], evidence: [], decision: nil
        )]
        let by = PilotPersonDTO(id: "guardian", name: "Richard", relation: "Anak", role: "guardian")
        let decision = PilotDecisionDTO(by: by, verdict: "scam", at: .now)

        pilot.applyHistory([historyDTO(id: id, decision: decision)])

        #expect(try #require(state.history.first?.decision).by.name == "Richard")
        #expect(state.history.first?.decision?.verdict == .scam)
    }

    @Test("Riwayat memetakan aman, bahaya, dan tidak dapat dinilai")
    func testHistoryPresentationMapsSafeReviewDangerAndUnassessed() {
        let presentations: [HistoryPresentation] = [.safe, .review, .danger, .unassessed]

        #expect(presentations.map(\.title) == ["Aman", "Bahaya", "Bahaya", "Tidak dapat dinilai"])
        #expect(presentations.map(\.symbol) == [
            "checkmark.circle.fill",
            "exclamationmark.triangle.fill",
            "exclamationmark.octagon.fill",
            "questionmark.circle.fill",
        ])
        #expect(presentations.map(\.colorRole) == [.safe, .danger, .danger, .neutral])

        let safe = CallRecord(
            id: UUID(), title: "Aman", callerDetail: "Kontak", channel: .cellular,
            startedAt: .now, duration: 30, level: .safe,
            signals: [], evidence: [], decision: nil
        )
        #expect(HistoryList.visibleRecords([safe], forGuardian: true) == [safe])
    }

    @Test("Profil pilot memilih persona dan mengurutkan pengawas aktif")
    func appliesRemoteProfile() {
        let (state, pilot) = makePilot()
        let parent = PilotPersonDTO(id: "parent", name: "Bu Sri", relation: "Ibu", role: "parent")
        let sinta = PilotPersonDTO(id: "sinta", name: "Sinta", relation: "Anak", role: "guardian")
        let richard = PilotPersonDTO(id: "richard", name: "Richard", relation: "Anak", role: "guardian")

        pilot.applyProfile(PilotProfileDTO(
            familyID: "family",
            member: richard,
            parent: parent,
            guardians: [sinta, richard]
        ))

        #expect(state.persona == .sinta)
        #expect(state.parent.name == "Bu Sri")
        #expect(state.guardians.first?.id == "richard")
        #expect(state.pilotRole == "guardian")
    }

    @Test("Alert pilot yang sudah selesai menunggu riwayat server tanpa notifikasi baru")
    func endedRemoteAlertDoesNotNotifyAgain() {
        let (state, pilot) = makePilot(persona: .sinta)
        state.history = []
        var alert = FamilyAlert(
            id: UUID(),
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
        alert.callEnded = true

        pilot.applyAlerts([alert])

        #expect(state.history.isEmpty)
        #expect(state.toast == nil)
    }
}
