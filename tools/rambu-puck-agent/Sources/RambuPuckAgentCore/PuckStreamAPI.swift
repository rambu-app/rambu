import Foundation

public enum PuckStreamEvent: Sendable {
    case ready
    case partial(String)
    case snapshot(ProtectionSession)
    case complete
    case failure(code: String, retryable: Bool)
}

public protocol PuckStreamSession: Sendable {
    func receive() async throws -> PuckStreamEvent
    func send(samples: [Int16]) async throws
    func finish() async throws
    func close() async
}

public protocol PuckStreamConnecting: Sendable {
    func connect(sessionID: String) async throws -> any PuckStreamSession
}

public struct PuckStreamAPI: PuckStreamConnecting, Sendable {
    private let serverURL: URL
    private let token: String
    private let session: URLSession

    public init(
        serverURL: URL,
        token: String,
        session: URLSession = .shared
    ) {
        self.serverURL = serverURL
        self.token = token
        self.session = session
    }

    public func request(sessionID: String) throws -> URLRequest {
        guard !token.isEmpty else { throw PuckAPIError.missingToken }
        var url = serverURL
        for component in ["api", "pucks", "sessions", sessionID, "stream"] {
            url.append(path: component)
        }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw PuckAPIError.invalidResponse
        }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        guard let streamURL = components.url else { throw PuckAPIError.invalidResponse }
        var request = URLRequest(url: streamURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    public func connect(sessionID: String) async throws -> any PuckStreamSession {
        let task = session.webSocketTask(with: try request(sessionID: sessionID))
        task.resume()
        return URLSessionPuckStreamSession(task: task)
    }

    public static func pcmData(samples: [Int16]) -> Data {
        var data = Data(capacity: samples.count * MemoryLayout<Int16>.size)
        for sample in samples {
            var value = sample.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        return data
    }
}

private actor URLSessionPuckStreamSession: PuckStreamSession {
    private struct Envelope: Decodable {
        let type: String
        let text: String?
        let snapshot: ProtectionSession?
        let code: String?
        let retryable: Bool?
    }

    private let task: URLSessionWebSocketTask
    private let decoder: JSONDecoder

    init(task: URLSessionWebSocketTask) {
        self.task = task
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        self.decoder = decoder
    }

    func receive() async throws -> PuckStreamEvent {
        let message = try await task.receive()
        let data: Data
        switch message {
        case .string(let value):
            data = Data(value.utf8)
        case .data(let value):
            data = value
        @unknown default:
            throw PuckAPIError.invalidResponse
        }
        let envelope = try decoder.decode(Envelope.self, from: data)
        switch envelope.type {
        case "ready":
            return .ready
        case "partial":
            guard let text = envelope.text else { throw PuckAPIError.invalidResponse }
            return .partial(text)
        case "snapshot":
            guard let snapshot = envelope.snapshot else { throw PuckAPIError.invalidResponse }
            return .snapshot(snapshot)
        case "complete":
            return .complete
        case "error":
            return .failure(
                code: envelope.code ?? "stream_error",
                retryable: envelope.retryable ?? false
            )
        default:
            throw PuckAPIError.invalidResponse
        }
    }

    func send(samples: [Int16]) async throws {
        try await task.send(.data(PuckStreamAPI.pcmData(samples: samples)))
    }

    func finish() async throws {
        try await task.send(.string(#"{"type":"finish"}"#))
    }

    func close() async {
        task.cancel(with: .normalClosure, reason: nil)
    }
}
