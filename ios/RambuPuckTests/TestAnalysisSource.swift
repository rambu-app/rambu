import Foundation
@testable import RambuPuck

struct ScenarioAnalysis: CallAnalysisSource {
    var interval: Duration = .seconds(5)
    var initialDelay: Duration = .milliseconds(1200)

    func assessments(for call: CallContext) -> AsyncThrowingStream<ChunkAssessment, Error> {
        let lines = AppLanguage.allCases
            .flatMap { Scenario.all(language: $0) }
            .first { $0.id == call.metadata.fixtureID && $0.title == call.metadata.title }?.lines ?? []
        let interval = interval
        let initialDelay = initialDelay
        return AsyncThrowingStream { continuation in
            let task = Task {
                var seen = Set<SignalKind>()
                var level = RiskLevel.safe
                for (index, line) in lines.enumerated() {
                    try? await Task.sleep(for: index == 0 ? initialDelay : interval)
                    if Task.isCancelled { break }
                    seen.formUnion(line.signals)
                    level = max(level, RiskRules.level(for: seen))
                    continuation.yield(ChunkAssessment(line: line, level: level, signals: line.signals))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

final class CountingFailureSource: CallAnalysisSource, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let error: BackendAnalysisError

    init(error: BackendAnalysisError) {
        self.error = error
    }

    var invocationCount: Int {
        lock.withLock { count }
    }

    func assessments(for call: CallContext) -> AsyncThrowingStream<ChunkAssessment, Error> {
        lock.withLock { count += 1 }
        return AsyncThrowingStream { continuation in
            continuation.finish(throwing: error)
        }
    }
}

final class FakeCallActivityMonitor: CallActivityMonitoring, @unchecked Sendable {
    let events: AsyncThrowingStream<CallActivityEvent, Error>
    private let continuation: AsyncThrowingStream<CallActivityEvent, Error>.Continuation
    private let lock = NSLock()
    private var refreshEvent: CallActivityEvent?

    init() {
        var captured: AsyncThrowingStream<CallActivityEvent, Error>.Continuation!
        events = AsyncThrowingStream { captured = $0 }
        continuation = captured
    }

    func send(_ event: CallActivityEvent) {
        continuation.yield(event)
    }

    func fail(_ error: Error) {
        continuation.finish(throwing: error)
    }

    func sendOnRefresh(_ event: CallActivityEvent) {
        lock.withLock { refreshEvent = event }
    }

    func refresh() {
        let event = lock.withLock {
            defer { refreshEvent = nil }
            return refreshEvent
        }
        if let event { continuation.yield(event) }
    }
}

final class RecordingCallAnalysisSession: CallAnalysisSession, @unchecked Sendable {
    let assessments: AsyncThrowingStream<ChunkAssessment, Error>
    let statusUpdates: AsyncStream<ProtectionStatus>

    private let assessmentContinuation: AsyncThrowingStream<ChunkAssessment, Error>.Continuation
    private let statusContinuation: AsyncStream<ProtectionStatus>.Continuation
    private let lock = NSLock()
    private let finishStatus: ProtectionStatus?
    private let finishAssessment: ChunkAssessment?
    private var finished = false
    private var cancelled = false

    init(
        finishStatus: ProtectionStatus? = nil,
        finishAssessment: ChunkAssessment? = nil
    ) {
        self.finishStatus = finishStatus
        self.finishAssessment = finishAssessment
        var capturedAssessment: AsyncThrowingStream<ChunkAssessment, Error>.Continuation!
        assessments = AsyncThrowingStream { capturedAssessment = $0 }
        assessmentContinuation = capturedAssessment
        var capturedStatus: AsyncStream<ProtectionStatus>.Continuation!
        statusUpdates = AsyncStream { capturedStatus = $0 }
        statusContinuation = capturedStatus
    }

    var didFinish: Bool { lock.withLock { finished } }
    var didCancel: Bool { lock.withLock { cancelled } }

    func send(_ status: ProtectionStatus) {
        statusContinuation.yield(status)
    }

    func finish() async throws {
        lock.withLock { finished = true }
        if let finishStatus { statusContinuation.yield(finishStatus) }
        if let finishAssessment { assessmentContinuation.yield(finishAssessment) }
        assessmentContinuation.finish()
        statusContinuation.finish()
    }

    func cancel() async throws {
        lock.withLock { cancelled = true }
        assessmentContinuation.finish()
        statusContinuation.finish()
    }
}

final class RecordingCallAnalysisSource: CallAnalysisSource, @unchecked Sendable {
    private let lock = NSLock()
    private let finishStatus: ProtectionStatus?
    private let finishAssessment: ChunkAssessment?
    let usesAuthoritativeRemoteAlerts: Bool
    private var contexts: [CallContext] = []
    private var sessions: [RecordingCallAnalysisSession] = []

    var startCount: Int { lock.withLock { contexts.count } }
    var latestSession: RecordingCallAnalysisSession? { lock.withLock { sessions.last } }

    init(
        finishStatus: ProtectionStatus? = nil,
        finishAssessment: ChunkAssessment? = nil,
        usesAuthoritativeRemoteAlerts: Bool = false
    ) {
        self.finishStatus = finishStatus
        self.finishAssessment = finishAssessment
        self.usesAuthoritativeRemoteAlerts = usesAuthoritativeRemoteAlerts
    }

    func start(for call: CallContext) async throws -> any CallAnalysisSession {
        let session = RecordingCallAnalysisSession(
            finishStatus: finishStatus,
            finishAssessment: finishAssessment
        )
        lock.withLock {
            contexts.append(call)
            sessions.append(session)
        }
        return session
    }

    func assessments(for call: CallContext) -> AsyncThrowingStream<ChunkAssessment, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
