import Foundation

public enum AgentCommand: Sendable {
    case pair
    case listen
}

public enum TranscriptionMode: String, Equatable, Sendable {
    case stream
    case chunk
}

public enum ConfigurationError: Error, CustomStringConvertible, Equatable {
    case missing(String)
    case invalidServerURL
    case invalidTranscriptionMode

    public var description: String {
        switch self {
        case .missing(let name):
            return "Environment variable \(name) is required."
        case .invalidServerURL:
            return "RAMBU_SERVER_URL must be an absolute http or https URL."
        case .invalidTranscriptionMode:
            return "RAMBU_TRANSCRIPTION_MODE must be stream or chunk."
        }
    }
}

public struct AgentConfiguration: Sendable {
    public let serverURL: URL
    public let puckToken: String?
    public let transcriptionMode: TranscriptionMode

    public init(environment: [String: String], command: AgentCommand) throws {
        guard let rawURL = environment["RAMBU_SERVER_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawURL.isEmpty else {
            throw ConfigurationError.missing("RAMBU_SERVER_URL")
        }
        guard let serverURL = URL(string: rawURL),
              let scheme = serverURL.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              serverURL.host != nil else {
            throw ConfigurationError.invalidServerURL
        }
        let token = environment["RAMBU_PUCK_TOKEN"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if command == .listen && (token?.isEmpty != false) {
            throw ConfigurationError.missing("RAMBU_PUCK_TOKEN")
        }
        let rawMode = environment["RAMBU_TRANSCRIPTION_MODE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? "stream"
        guard let transcriptionMode = TranscriptionMode(rawValue: rawMode) else {
            throw ConfigurationError.invalidTranscriptionMode
        }
        self.serverURL = serverURL
        self.puckToken = token?.isEmpty == false ? token : nil
        self.transcriptionMode = transcriptionMode
    }
}
