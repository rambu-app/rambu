import Foundation
import Testing
@testable import RambuPuck

private final class ProtectionURLProtocol: URLProtocol, @unchecked Sendable {
    struct Stub: Sendable {
        let status: Int
        let data: Data
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var stubs: [Stub] = []
    nonisolated(unsafe) private static var recorded: [URLRequest] = []

    static func reset(_ values: [Stub]) {
        lock.withLock {
            stubs = values
            recorded = []
        }
    }

    static func requests() -> [URLRequest] {
        lock.withLock { recorded }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var recordedRequest = request
        if recordedRequest.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var body = Data()
            var buffer = [UInt8](repeating: 0, count: 1_024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(buffer, count: count)
            }
            recordedRequest.httpBody = body
        }
        let stub: Stub = Self.lock.withLock {
            Self.recorded.append(recordedRequest)
            return Self.stubs.removeFirst()
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: stub.status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
struct ProtectionCallAnalysisSourceTests {
    private func source(pollInterval: Duration = .zero) -> ProtectionCallAnalysisSource {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProtectionURLProtocol.self]
        return ProtectionCallAnalysisSource(
            serverURL: "http://server.test",
            accessToken: { "parent-token" },
            session: URLSession(configuration: configuration),
            pollInterval: pollInterval
        )
    }

    private func context() -> CallContext {
        CallContext(
            id: UUID(uuidString: "7F011753-8F09-4A45-8812-8A4591A96B3C")!,
            metadata: CallMetadata.production,
            startedAt: Date(timeIntervalSince1970: 1_759_313_600),
            language: .english
        )
    }

    private func snapshot(
        revision: Int,
        status: String,
        transcript: String = "",
        assessment: [String: Any]? = nil,
        outcome: String? = nil,
        failure: [String: String]? = nil,
        endRequested: Bool = false
    ) throws -> Data {
        var value: [String: Any] = [
            "id": "session-1",
            "call_id": "7f011753-8f09-4a45-8812-8a4591a96b3c",
            "channel": NSNull(),
            "language": "en",
            "status": status,
            "puck_connected": status != "waiting_for_puck",
            "masked_transcript": transcript,
            "assessment": assessment ?? NSNull(),
            "outcome": outcome ?? NSNull(),
            "end_requested": endRequested,
            "revision": revision,
            "next_sequence": 0,
            "started_at": "2026-10-01T10:00:00Z",
            "end_requested_at": endRequested ? "2026-10-01T10:01:00Z" : NSNull(),
            "ended_at": status == "completed" ? "2026-10-01T10:01:01Z" : NSNull(),
            "failure": failure ?? NSNull(),
        ]
        if assessment == nil { value["assessment"] = NSNull() }
        return try JSONSerialization.data(withJSONObject: value)
    }

    private var reviewAssessment: [String: Any] {
        [
            "risk_level": "needs_review",
            "signals": ["impersonation"],
            "evidence": [["quote": "Saya dari bank.", "signals": ["impersonation"]]],
            "explanation": "Penelepon mengaku dari bank.",
            "recommended_action": "Verifikasi melalui kanal resmi.",
        ]
    }

    @Test("Production session posts CallKit identity and emits only new revisions")
    func createsAndPollsByRevision() async throws {
        ProtectionURLProtocol.reset([
            .init(status: 201, data: try snapshot(revision: 0, status: "waiting_for_puck")),
            .init(
                status: 200,
                data: try snapshot(
                    revision: 1,
                    status: "listening",
                    transcript: "Saya dari bank.",
                    assessment: reviewAssessment
                )
            ),
            .init(
                status: 200,
                data: try snapshot(
                    revision: 1,
                    status: "listening",
                    transcript: "Saya dari bank.",
                    assessment: reviewAssessment
                )
            ),
            .init(
                status: 200,
                data: try snapshot(
                    revision: 2,
                    status: "completed",
                    transcript: "Saya dari bank.",
                    assessment: reviewAssessment,
                    outcome: "analyzed"
                )
            ),
        ])
        let analysisSession = try await source().start(for: context())
        async let statuses = collectStatuses(analysisSession.statusUpdates)
        var chunks: [ChunkAssessment] = []
        for try await chunk in analysisSession.assessments { chunks.append(chunk) }

        #expect(chunks.count == 1)
        #expect(chunks.first?.line.speaker == .unknown)
        #expect(chunks.first?.line.offset == nil)
        #expect(await statuses == [.waitingForPuck, .listening, .completed])
        let requests = ProtectionURLProtocol.requests()
        let create = try #require(requests.first)
        #expect(create.httpMethod == "POST")
        #expect(create.url?.path == "/api/protection/sessions")
        #expect(create.value(forHTTPHeaderField: "Authorization") == "Bearer parent-token")
        let body = try #require(create.httpBody)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["call_id"] as? String == "7F011753-8F09-4A45-8812-8A4591A96B3C")
        #expect(object["title"] as? String == "Panggilan terdeteksi")
        #expect(object["caller_detail"] as? String == "Nomor tidak tersedia")
        #expect(object["language"] as? String == "en")
    }

    @Test("Finish posts end while cancel deletes the remote session")
    func distinguishesFinishAndCancel() async throws {
        ProtectionURLProtocol.reset([
            .init(status: 201, data: try snapshot(revision: 0, status: "waiting_for_puck")),
            .init(
                status: 200,
                data: try snapshot(
                    revision: 1,
                    status: "completed",
                    outcome: "no_speech",
                    endRequested: true
                )
            ),
            .init(status: 201, data: try snapshot(revision: 0, status: "waiting_for_puck")),
            .init(status: 204, data: Data()),
        ])
        let source = source(pollInterval: .seconds(60))
        let finished = try await source.start(for: context())
        try await finished.finish()
        let cancelled = try await source.start(for: context())
        try await cancelled.cancel()

        let requests = ProtectionURLProtocol.requests()
        #expect(requests.contains { $0.httpMethod == "POST" && $0.url?.path == "/api/protection/sessions/session-1/end" })
        #expect(requests.contains { $0.httpMethod == "DELETE" && $0.url?.path == "/api/protection/sessions/session-1" })
    }

    @Test("Structured backend failure reaches the assessment stream")
    func propagatesBackendFailure() async throws {
        ProtectionURLProtocol.reset([
            .init(
                status: 201,
                data: try snapshot(
                    revision: 1,
                    status: "error",
                    failure: ["code": "analysis_timeout", "message": "Langflow tidak merespons."]
                )
            )
        ])
        let analysisSession = try await source().start(for: context())

        do {
            for try await _ in analysisSession.assessments {}
            Issue.record("Expected backend failure")
        } catch let error as BackendAnalysisError {
            #expect(error.code == "analysis_timeout")
            #expect(error.detail == "Langflow tidak merespons.")
        }
    }

    @Test("Cancel preserves the backend deletion error")
    func propagatesCancelFailure() async throws {
        let error = try JSONSerialization.data(withJSONObject: [
            "detail": [
                "code": "session_delete_failed",
                "message": "Sesi tidak dapat dihapus.",
            ],
        ])
        ProtectionURLProtocol.reset([
            .init(status: 201, data: try snapshot(revision: 0, status: "waiting_for_puck")),
            .init(status: 503, data: error),
        ])
        let analysisSession = try await source(pollInterval: .seconds(60)).start(for: context())

        do {
            try await analysisSession.cancel()
            Issue.record("Expected cancellation failure")
        } catch let error as BackendAnalysisError {
            #expect(error.code == "http_503")
            #expect(error.detail == "Sesi tidak dapat dihapus.")
        }
    }

    private func collectStatuses(
        _ stream: AsyncStream<ProtectionStatus>
    ) async -> [ProtectionStatus] {
        var values: [ProtectionStatus] = []
        for await value in stream { values.append(value) }
        return values
    }
}
