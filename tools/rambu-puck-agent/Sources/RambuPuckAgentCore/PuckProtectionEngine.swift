import Foundation

public enum PuckProtectionState: Equatable, Sendable {
    case idle
    case starting
    case listening(sessionID: String)
    case ending(sessionID: String)
    case retryEnding(sessionID: String, message: String)
    case completed(sessionID: String)
    case error(String)
}

public enum PuckProtectionEvent: Equatable, Sendable {
    case state(PuckProtectionState)
    case transcript(String)
    case partialTranscript(String)
    case warning(severity: PuckRiskLevel, warning: PuckWarning)
}

public enum PuckProtectionEngineError: Error, CustomStringConvertible, Sendable {
    case invalidState(PuckProtectionState)
    case streamFailed(String)

    public var description: String {
        switch self {
        case .invalidState(let state):
            return "Protection cannot perform that action from state \(state)."
        case .streamFailed(let message):
            return "Streaming transcription failed: \(message)"
        }
    }
}

public actor PuckProtectionEngine {
    public nonisolated let events: AsyncStream<PuckProtectionEvent>

    private let api: PuckAPI
    private let capture: any AudioCapturing
    private let streamAPI: (any PuckStreamConnecting)?
    private let framesPerChunk: Int
    private let eventContinuation: AsyncStream<PuckProtectionEvent>.Continuation

    private var state: PuckProtectionState = .idle
    private var sessionID: String?
    private var baseSequence = 0
    private var chunker: PCMChunker
    private var transcriptProgress = PuckTranscriptProgress()
    private var warningGate = PuckWarningGate()
    private var streamTask: Task<Void, Never>?
    private var providerTask: Task<Void, Never>?
    private var activeStream: (any PuckStreamSession)?
    private var streamSnapshotSequence = 0
    private var endRequested = false
    private var pendingFinal: PCMChunk?

    public init(
        api: PuckAPI,
        capture: any AudioCapturing = MicrophoneCapture(),
        streamAPI: (any PuckStreamConnecting)? = nil,
        framesPerChunk: Int = 80_000
    ) {
        precondition(framesPerChunk > 0)
        self.api = api
        self.capture = capture
        self.streamAPI = streamAPI
        self.framesPerChunk = framesPerChunk
        self.chunker = PCMChunker(framesPerChunk: framesPerChunk)
        let pair = AsyncStream<PuckProtectionEvent>.makeStream()
        self.events = pair.stream
        self.eventContinuation = pair.continuation
    }

    deinit {
        streamTask?.cancel()
        providerTask?.cancel()
        eventContinuation.finish()
    }

    public func currentState() -> PuckProtectionState {
        state
    }

    public func start(callID: UUID, startedAt: Date) async throws {
        switch state {
        case .idle, .completed, .error:
            break
        default:
            throw PuckProtectionEngineError.invalidState(state)
        }

        resetSessionState()
        transition(to: .starting)
        let session: ProtectionSession
        do {
            session = try await api.startOrJoinSession(callID: callID, startedAt: startedAt)
        } catch {
            transition(to: .error(String(describing: error)))
            throw error
        }

        if let streamAPI {
            let candidate: any PuckStreamSession
            do {
                candidate = try await streamAPI.connect(sessionID: session.id)
                let initial = try await candidate.receive()
                guard case .ready = initial else {
                    await candidate.close()
                    return try await startChunkCapture(session)
                }
            } catch {
                activeStream = nil
                try await startChunkCapture(session)
                return
            }
            activeStream = candidate
            try await startStreamingCapture(session, stream: candidate)
            return
        }
        try await startChunkCapture(session)
    }

    private func startChunkCapture(_ session: ProtectionSession) async throws {
        do {
            let audio = try await capture.start()
            sessionID = session.id
            baseSequence = session.nextSequence
            transition(to: .listening(sessionID: session.id))
            streamTask = Task { [weak self] in
                do {
                    for try await samples in audio {
                        guard !Task.isCancelled else { return }
                        await self?.consume(samples)
                    }
                    await self?.streamFinishedNormally()
                } catch {
                    await self?.streamFailed(error)
                }
            }
        } catch {
            capture.stop()
            transition(to: .error(String(describing: error)))
            throw error
        }
    }

    private func startStreamingCapture(
        _ session: ProtectionSession,
        stream: any PuckStreamSession
    ) async throws {
        do {
            let audio = try await capture.start()
            sessionID = session.id
            baseSequence = session.nextSequence
            transition(to: .listening(sessionID: session.id))
            streamTask = Task { [weak self] in
                do {
                    for try await samples in audio {
                        guard !Task.isCancelled else { return }
                        try await stream.send(samples: samples)
                    }
                    await self?.streamFinishedNormally()
                } catch {
                    await self?.streamFailed(error)
                }
            }
            providerTask = Task { [weak self] in
                do {
                    while !Task.isCancelled {
                        let event = try await stream.receive()
                        if await self?.handleStreamEvent(event) == true { return }
                    }
                } catch {
                    await self?.streamFailed(error)
                }
            }
        } catch {
            await stream.close()
            activeStream = nil
            capture.stop()
            transition(to: .error(String(describing: error)))
            throw error
        }
    }

    public func end() async throws {
        guard case .listening(let id) = state else {
            throw PuckProtectionEngineError.invalidState(state)
        }
        endRequested = true
        transition(to: .ending(sessionID: id))
        capture.stop()
        await streamTask?.value
        streamTask = nil

        if let activeStream {
            do {
                try await activeStream.finish()
                await providerTask?.value
                providerTask = nil
                await activeStream.close()
                self.activeStream = nil
                guard case .completed = state else {
                    throw PuckProtectionEngineError.streamFailed("stream ended without completion")
                }
                return
            } catch {
                await activeStream.close()
                self.activeStream = nil
                transition(to: .error(String(describing: error)))
                throw error
            }
        }

        guard let final = pendingFinal ?? chunker.finish() else {
            throw PuckProtectionEngineError.invalidState(state)
        }
        pendingFinal = final
        do {
            try await upload(final, sessionID: id)
            pendingFinal = nil
            transition(to: .completed(sessionID: id))
        } catch {
            transition(to: .retryEnding(sessionID: id, message: String(describing: error)))
            throw error
        }
    }

    public func retryEnd() async throws {
        guard case .retryEnding(let id, _) = state, let final = pendingFinal else {
            throw PuckProtectionEngineError.invalidState(state)
        }
        transition(to: .ending(sessionID: id))
        do {
            try await upload(final, sessionID: id)
            pendingFinal = nil
            transition(to: .completed(sessionID: id))
        } catch {
            transition(to: .retryEnding(sessionID: id, message: String(describing: error)))
            throw error
        }
    }

    private func resetSessionState() {
        streamTask?.cancel()
        streamTask = nil
        providerTask?.cancel()
        providerTask = nil
        activeStream = nil
        streamSnapshotSequence = 0
        sessionID = nil
        baseSequence = 0
        chunker = PCMChunker(framesPerChunk: framesPerChunk)
        transcriptProgress = PuckTranscriptProgress()
        warningGate = PuckWarningGate()
        endRequested = false
        pendingFinal = nil
    }

    private func consume(_ samples: [Int16]) async {
        guard case .listening(let id) = state else { return }
        for chunk in chunker.append(samples) {
            do {
                try await upload(chunk, sessionID: id)
            } catch {
                capture.stop()
                transition(to: .error(String(describing: error)))
                streamTask?.cancel()
                return
            }
        }
    }

    private func upload(_ chunk: PCMChunk, sessionID: String) async throws {
        let sequence = baseSequence + chunk.sequence
        let updated = try await api.uploadChunk(
            sessionID: sessionID,
            sequence: sequence,
            final: chunk.isFinal,
            wav: WAVEncoder.encode(samples: chunk.samples)
        )
        eventContinuation.yield(.transcript(
            transcriptProgress.line(
                sequence: sequence,
                cumulativeTranscript: updated.maskedTranscript
            )
        ))
        if let assessment = updated.assessment,
           let warning = warningGate.warning(for: assessment) {
            eventContinuation.yield(.warning(severity: assessment.riskLevel, warning: warning))
        }
    }

    private func handleStreamEvent(_ event: PuckStreamEvent) async -> Bool {
        switch event {
        case .ready:
            return false
        case .partial(let text):
            eventContinuation.yield(.partialTranscript(text))
            return false
        case .snapshot(let snapshot):
            eventContinuation.yield(.transcript(
                transcriptProgress.line(
                    sequence: streamSnapshotSequence,
                    cumulativeTranscript: snapshot.maskedTranscript
                )
            ))
            streamSnapshotSequence += 1
            if let assessment = snapshot.assessment,
               let warning = warningGate.warning(for: assessment) {
                eventContinuation.yield(.warning(
                    severity: assessment.riskLevel,
                    warning: warning
                ))
            }
            return false
        case .complete:
            if let sessionID {
                transition(to: .completed(sessionID: sessionID))
            }
            return true
        case .failure(let code, _):
            streamFailed(PuckProtectionEngineError.streamFailed(code))
            return true
        }
    }

    private func streamFinishedNormally() {
        guard !endRequested, case .listening = state else { return }
        capture.stop()
        transition(to: .error("Microphone capture ended unexpectedly."))
    }

    private func streamFailed(_ error: Error) {
        guard !endRequested, case .listening = state else { return }
        capture.stop()
        transition(to: .error(String(describing: error)))
    }

    private func transition(to newState: PuckProtectionState) {
        state = newState
        eventContinuation.yield(.state(newState))
    }
}
