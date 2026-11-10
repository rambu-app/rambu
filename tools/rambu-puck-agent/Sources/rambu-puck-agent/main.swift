import Darwin
import Foundation
import RambuPuckAgentCore

private actor StopSignal {
    private(set) var requested = false
    private(set) var failure: String?

    func request() {
        requested = true
    }

    func fail(_ message: String) {
        failure = message
        requested = true
    }
}

private enum AgentRuntimeError: Error, CustomStringConvertible {
    case monitoring(String)

    var description: String {
        switch self {
        case .monitoring(let message):
            return "Session monitoring failed: \(message)"
        }
    }
}

@main
struct RambuPuckAgentMain {
    static func main() async {
        do {
            let arguments = try CLIArguments.parse(Array(CommandLine.arguments.dropFirst()))
            switch arguments {
            case .help:
                printUsage()
            case .pair(let code, let name):
                try await pair(code: code, name: name)
            case .listen(let detectAudio):
                try await listen(detectAudio: detectAudio)
            case .manual:
                try await listenManually()
            }
        } catch {
            FileHandle.standardError.write(Data("Error: \(error)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    private static func pair(code: String, name: String) async throws {
        let configuration = try AgentConfiguration(
            environment: ProcessInfo.processInfo.environment,
            command: .pair
        )
        let api = PuckAPI(serverURL: configuration.serverURL, token: nil)
        let puck = try await api.pair(code: code, displayName: name)
        print(puck.accessToken)
    }

    private static func listen(detectAudio: Bool) async throws {
        let configuration = try AgentConfiguration(
            environment: ProcessInfo.processInfo.environment,
            command: .listen
        )
        let api = PuckAPI(serverURL: configuration.serverURL, token: configuration.puckToken)
        let streamAPI: (any PuckStreamConnecting)? = configuration.transcriptionMode == .stream
            ? PuckStreamAPI(serverURL: configuration.serverURL, token: configuration.puckToken!)
            : nil
        if detectAudio {
            print("Rambu puck agent is listening for WhatsApp call audio near the Mac.")
        } else {
            print("Rambu puck agent is waiting for an active call.")
        }
        while !Task.isCancelled {
            if let session = try await api.activeSession() {
                if detectAudio {
                    try await diagnosticRecord(
                        session: session,
                        api: api,
                        initialSamples: [],
                        endsAfterSilence: true
                    )
                } else {
                    _ = try await protectWithEngine(
                        api: api,
                        streamAPI: streamAPI,
                        stopsOnEnter: false
                    )
                }
                print("Protection session \(session.id) completed.")
            } else if detectAudio {
                let preRoll = try await waitForAudioActivation()
                print("Audio detected. Starting or joining WhatsApp protection.")
                let session = try await api.startOrJoinSession(
                    callID: UUID(),
                    startedAt: .now
                )
                try await diagnosticRecord(
                    session: session,
                    api: api,
                    initialSamples: preRoll,
                    endsAfterSilence: true
                )
                print("Protection session \(session.id) completed. Listening for the next call.")
            } else {
                try await Task.sleep(for: .seconds(1))
            }
        }
    }

    private static func listenManually() async throws {
        let configuration = try AgentConfiguration(
            environment: ProcessInfo.processInfo.environment,
            command: .listen
        )
        let api = PuckAPI(serverURL: configuration.serverURL, token: configuration.puckToken)
        let streamAPI: (any PuckStreamConnecting)? = configuration.transcriptionMode == .stream
            ? PuckStreamAPI(serverURL: configuration.serverURL, token: configuration.puckToken!)
            : nil
        print("Rambu demo control is ready.")
        while !Task.isCancelled {
            print("Press Enter after the call is answered to start protection.")
            guard readLine() != nil else { return }
            let sessionID = try await protectWithEngine(
                api: api,
                streamAPI: streamAPI,
                stopsOnEnter: true
            )
            print("Protection session \(sessionID) completed.")
        }
    }

    private static func protectWithEngine(
        api: PuckAPI,
        streamAPI: (any PuckStreamConnecting)?,
        stopsOnEnter: Bool
    ) async throws -> String {
        let engine = PuckProtectionEngine(api: api, streamAPI: streamAPI)
        let events = Task {
            for await event in engine.events {
                switch event {
                case .transcript(let line):
                    emitTranscript(line)
                case .partialTranscript(let line):
                    emitTranscript(line)
                case .warning(_, let warning):
                    emit(warning)
                case .state:
                    break
                }
            }
        }
        defer { events.cancel() }

        try await engine.start(callID: UUID(), startedAt: .now)
        guard case .listening(let sessionID) = await engine.currentState() else {
            throw AgentRuntimeError.monitoring("Protection did not enter the listening state.")
        }
        print("Active call found. Capturing external audio with the Mac microphone.")

        if stopsOnEnter {
            print("Protection started. Press Enter after the call ends.")
            _ = await Task.detached { readLine() }.value
        } else {
            while !Task.isCancelled {
                try await Task.sleep(for: .milliseconds(500))
                guard let current = try await api.activeSession() else { break }
                if current.id != sessionID || current.endRequested { break }
            }
        }
        try await engine.end()
        return sessionID
    }

    private static func waitForAudioActivation() async throws -> [Int16] {
        let capture = MicrophoneCapture()
        let stream = try await capture.start()
        defer { capture.stop() }
        var gate = PuckAudioGate()
        for try await samples in stream {
            if case .activated(let preRoll) = gate.ingest(samples) {
                return preRoll
            }
        }
        throw AgentRuntimeError.monitoring("Microphone capture ended before audio was detected.")
    }

    // Automatic sound activation remains a diagnostic-only command. The normal
    // CLI and menu app both use PuckProtectionEngine's explicit Start/End flow.
    private static func diagnosticRecord(
        session: ProtectionSession,
        api: PuckAPI,
        initialSamples: [Int16],
        endsAfterSilence: Bool,
        stopsOnEnter: Bool = false
    ) async throws {
        print("Active call found. Capturing external audio with the Mac microphone.")
        let capture = MicrophoneCapture()
        let stream = try await capture.start()
        let signal = StopSignal()
        let monitor: Task<Void, Never>
        if stopsOnEnter {
            monitor = Task.detached {
                _ = readLine()
                await signal.request()
            }
        } else {
            monitor = Task {
                do {
                    while !Task.isCancelled {
                        try await Task.sleep(for: .milliseconds(500))
                        guard let current = try await api.activeSession() else {
                            await signal.request()
                            return
                        }
                        if current.id != session.id || current.endRequested {
                            await signal.request()
                            return
                        }
                    }
                } catch is CancellationError {
                    return
                } catch {
                    await signal.fail(String(describing: error))
                }
            }
        }
        defer {
            monitor.cancel()
            capture.stop()
        }

        var chunker = PCMChunker()
        var transcriptProgress = PuckTranscriptProgress()
        var warningGate = PuckWarningGate()
        var audioGate = PuckAudioGate(initiallyActive: true)

        for chunk in chunker.append(initialSamples) {
            let updated = try await upload(chunk, sessionID: session.id, api: api)
            emitTranscript(
                transcriptProgress.line(
                    sequence: chunk.sequence,
                    cumulativeTranscript: updated.maskedTranscript
                )
            )
            if let warning = warningGate.warning(for: updated.assessment) {
                emit(warning)
            }
        }
        for try await samples in stream {
            for chunk in chunker.append(samples) {
                let updated = try await upload(chunk, sessionID: session.id, api: api)
                emitTranscript(
                    transcriptProgress.line(
                        sequence: chunk.sequence,
                        cumulativeTranscript: updated.maskedTranscript
                    )
                )
                if let warning = warningGate.warning(for: updated.assessment) {
                    emit(warning)
                }
            }
            if endsAfterSilence, audioGate.ingest(samples) == .ended {
                print("Sustained silence detected. Finishing the protection session.")
                break
            }
            if await signal.requested { break }
        }
        if let failure = await signal.failure {
            throw AgentRuntimeError.monitoring(failure)
        }
        capture.stop()
        if let final = chunker.finish() {
            let updated = try await upload(final, sessionID: session.id, api: api)
            emitTranscript(
                transcriptProgress.line(
                    sequence: final.sequence,
                    cumulativeTranscript: updated.maskedTranscript
                )
            )
            if let warning = warningGate.warning(for: updated.assessment) {
                emit(warning)
            }
        }
    }

    private static func upload(
        _ chunk: PCMChunk,
        sessionID: String,
        api: PuckAPI
    ) async throws -> ProtectionSession {
        try await api.uploadChunk(
            sessionID: sessionID,
            sequence: chunk.sequence,
            final: chunk.isFinal,
            wav: WAVEncoder.encode(samples: chunk.samples)
        )
    }

    private static func emitTranscript(_ line: String) {
        FileHandle.standardOutput.write(Data("\(line)\n".utf8))
    }

    private static func emit(_ warning: PuckWarning) {
        let message = """
        \u{7}
        ⚠️ RAMBU WARNING: \(warning.title)
        \(warning.recommendedAction)

        """
        FileHandle.standardError.write(Data(message.utf8))
    }

    private static func printUsage() {
        print(
            """
            Usage:
              rambu-puck-agent pair --code 123456 --name "Mac puck"
              rambu-puck-agent listen
              rambu-puck-agent listen --manual
              rambu-puck-agent listen --detect-audio

            Required environment:
              RAMBU_SERVER_URL   Backend base URL
              RAMBU_PUCK_TOKEN   Token printed by pair (listen only)
              RAMBU_TRANSCRIPTION_MODE   stream (default) or chunk
            """
        )
    }
}
