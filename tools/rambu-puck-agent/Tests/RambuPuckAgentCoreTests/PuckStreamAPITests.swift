import Foundation
import XCTest
@testable import RambuPuckAgentCore

private final class StreamAudioCapture: AudioCapturing, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<[Int16], Error>.Continuation?
    private var starts = 0
    private var stops = 0

    func start() async throws -> AsyncThrowingStream<[Int16], Error> {
        lock.withLock {
            starts += 1
            return AsyncThrowingStream { continuation in
                self.continuation = continuation
            }
        }
    }

    func stop() {
        let continuation = lock.withLock {
            stops += 1
            let value = continuation
            self.continuation = nil
            return value
        }
        continuation?.finish()
    }

    func yield(_ samples: [Int16]) {
        lock.withLock { continuation }?.yield(samples)
    }

    var startCount: Int { lock.withLock { starts } }
    var stopCount: Int { lock.withLock { stops } }
}

private actor StreamEngineTransport {
    private var results: [Result<(Data, HTTPURLResponse), Error>]
    private(set) var requests: [URLRequest] = []

    init(_ results: [Result<(Data, HTTPURLResponse), Error>]) {
        self.results = results
    }

    func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        return try results.removeFirst().get()
    }
}

private actor FakeStreamSession: PuckStreamSession {
    private var events: [PuckStreamEvent] = []
    private var waiter: CheckedContinuation<PuckStreamEvent, Error>?
    private(set) var sent: [[Int16]] = []
    private(set) var finishes = 0
    private(set) var closes = 0
    private let finishEvents: [PuckStreamEvent]

    init(finishEvents: [PuckStreamEvent] = []) {
        self.finishEvents = finishEvents
    }

    func receive() async throws -> PuckStreamEvent {
        if !events.isEmpty { return events.removeFirst() }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }

    func send(samples: [Int16]) async throws {
        sent.append(samples)
    }

    func finish() async throws {
        finishes += 1
        for event in finishEvents { yield(event) }
    }

    func close() async {
        closes += 1
    }

    func yield(_ event: PuckStreamEvent) {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: event)
        } else {
            events.append(event)
        }
    }
}

private struct FakeStreamConnector: PuckStreamConnecting {
    let session: FakeStreamSession

    func connect(sessionID: String) async throws -> any PuckStreamSession {
        session
    }
}

final class PuckStreamAPITests: XCTestCase {
    func testBuildsAuthenticatedWebSocketRequest() throws {
        let api = PuckStreamAPI(
            serverURL: URL(string: "https://api.rambu.sfatimah.com/base")!,
            token: "puck-secret"
        )

        let request = try api.request(sessionID: "session 1")

        XCTAssertEqual(
            request.url?.absoluteString,
            "wss://api.rambu.sfatimah.com/base/api/pucks/sessions/session%201/stream"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer puck-secret")
    }

    func testPCMEncodingIsSignedLittleEndian() {
        XCTAssertEqual(
            PuckStreamAPI.pcmData(samples: [0x1234, -2]),
            Data([0x34, 0x12, 0xfe, 0xff])
        )
    }

    func testCaptureStartsOnlyAfterReadyAndStreamsPCM() async throws {
        let capture = StreamAudioCapture()
        let stream = FakeStreamSession()
        let transport = StreamEngineTransport([
            .success((Data(#"{"detail":"missing"}"#.utf8), streamResponse(404))),
            .success((streamSessionJSON(id: "session-1", nextSequence: 0), streamResponse(201))),
        ])
        let engine = makeStreamingEngine(
            transport: transport,
            capture: capture,
            connector: FakeStreamConnector(session: stream)
        )

        let start = Task { try await engine.start(callID: UUID(), startedAt: .now) }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(capture.startCount, 0)

        await stream.yield(.ready)
        try await start.value
        XCTAssertEqual(capture.startCount, 1)
        capture.yield([1, -2, 3])
        try await waitUntil { await stream.sent.count == 1 }
        let sent = await stream.sent
        XCTAssertEqual(sent, [[1, -2, 3]])
    }

    func testFailureAfterReadyStopsWithoutChunkReplay() async throws {
        let capture = StreamAudioCapture()
        let stream = FakeStreamSession()
        await stream.yield(.ready)
        let transport = StreamEngineTransport([
            .success((Data(#"{"detail":"missing"}"#.utf8), streamResponse(404))),
            .success((streamSessionJSON(id: "session-1", nextSequence: 0), streamResponse(201))),
        ])
        let engine = makeStreamingEngine(
            transport: transport,
            capture: capture,
            connector: FakeStreamConnector(session: stream)
        )

        try await engine.start(callID: UUID(), startedAt: .now)
        capture.yield([7, 8])
        try await waitUntil { await stream.sent.count == 1 }
        await stream.yield(.failure(code: "transcription_unavailable", retryable: false))
        try await waitUntil {
            if case .error = await engine.currentState() { return true }
            return false
        }

        let uploads = await transport.requests.filter { $0.url?.path.contains("/chunks") == true }
        XCTAssertTrue(uploads.isEmpty)
        XCTAssertEqual(capture.stopCount, 1)
    }

    func testFailureBeforeReadyFallsBackToExistingChunkPath() async throws {
        let capture = StreamAudioCapture()
        let stream = FakeStreamSession()
        await stream.yield(.failure(code: "provider_unavailable", retryable: true))
        let transport = StreamEngineTransport([
            .success((Data(#"{"detail":"missing"}"#.utf8), streamResponse(404))),
            .success((streamSessionJSON(id: "session-1", nextSequence: 0), streamResponse(201))),
            .success((streamSessionJSON(id: "session-1", status: "completed", nextSequence: 1), streamResponse(200))),
        ])
        let engine = makeStreamingEngine(
            transport: transport,
            capture: capture,
            connector: FakeStreamConnector(session: stream)
        )

        try await engine.start(callID: UUID(), startedAt: .now)
        XCTAssertEqual(capture.startCount, 1)
        try await engine.end()

        let uploads = await transport.requests.filter { $0.url?.path.contains("/chunks") == true }
        XCTAssertEqual(uploads.count, 1)
        let closes = await stream.closes
        XCTAssertEqual(closes, 1)
    }

    func testFinishWaitsForSnapshotAndComplete() async throws {
        let capture = StreamAudioCapture()
        let completed = streamSession(
            id: "session-1",
            status: "completed",
            transcript: "Halo"
        )
        let stream = FakeStreamSession(finishEvents: [.snapshot(completed), .complete])
        await stream.yield(.ready)
        let transport = StreamEngineTransport([
            .success((Data(#"{"detail":"missing"}"#.utf8), streamResponse(404))),
            .success((streamSessionJSON(id: "session-1", nextSequence: 0), streamResponse(201))),
        ])
        let engine = makeStreamingEngine(
            transport: transport,
            capture: capture,
            connector: FakeStreamConnector(session: stream)
        )

        try await engine.start(callID: UUID(), startedAt: .now)
        try await engine.end()

        let state = await engine.currentState()
        let finishes = await stream.finishes
        XCTAssertEqual(state, .completed(sessionID: "session-1"))
        XCTAssertEqual(finishes, 1)
    }

    private func makeStreamingEngine(
        transport: StreamEngineTransport,
        capture: StreamAudioCapture,
        connector: FakeStreamConnector
    ) -> PuckProtectionEngine {
        let api = PuckAPI(
            serverURL: URL(string: "https://api.rambu.sfatimah.com")!,
            token: "puck-token",
            retryDelaysNanoseconds: [],
            transport: { request in try await transport.send(request) }
        )
        return PuckProtectionEngine(api: api, capture: capture, streamAPI: connector)
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for condition")
    }
}

private func streamResponse(_ status: Int) -> HTTPURLResponse {
    HTTPURLResponse(
        url: URL(string: "https://api.rambu.sfatimah.com")!,
        statusCode: status,
        httpVersion: nil,
        headerFields: nil
    )!
}

private func streamSessionJSON(
    id: String,
    status: String = "listening",
    nextSequence: Int
) -> Data {
    Data(
        """
        {"id":"\(id)","status":"\(status)","end_requested":false,"next_sequence":\(nextSequence),"masked_transcript":"","assessment":null}
        """.utf8
    )
}

private func streamSession(
    id: String,
    status: String,
    transcript: String
) -> ProtectionSession {
    let data = Data(
        """
        {"id":"\(id)","status":"\(status)","end_requested":false,"next_sequence":0,"masked_transcript":"\(transcript)","assessment":null}
        """.utf8
    )
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try! decoder.decode(ProtectionSession.self, from: data)
}
