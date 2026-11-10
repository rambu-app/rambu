import Combine
import Foundation
import RambuPuckAgentCore

public protocol PuckPairing: Sendable {
    func pair(code: String, displayName: String) async throws -> PairedPuck
}

extension PuckAPI: PuckPairing {}

public protocol PuckProtectionServing: Sendable {
    var events: AsyncStream<PuckProtectionEvent> { get }
    func start(callID: UUID, startedAt: Date) async throws
    func end() async throws
    func retryEnd() async throws
}

extension PuckProtectionEngine: PuckProtectionServing {}

public typealias PuckPairerFactory = @Sendable (URL) -> any PuckPairing
public typealias PuckEngineFactory = @Sendable (URL, String) -> any PuckProtectionServing

@MainActor
public final class PuckControllerViewModel: ObservableObject {
    public static let defaultServerURL = "https://rambu-api.sfatimah.com"
    public static let serverURLKey = "RambuPuckController.serverURL"
    public static let displayNameKey = "RambuPuckController.displayName"
    public static let shortcutEnabledKey = "RambuPuckController.shortcutEnabled"
    private static let retiredServerURL = "https://api.rambu.sfatimah.com"

    @Published public private(set) var state: PuckControllerState
    @Published public var serverURLText: String
    @Published public var displayName: String
    @Published public var pairingCode = ""
    @Published public private(set) var transcriptLines: [String] = []
    @Published public private(set) var latestWarning: PuckWarning?
    @Published public private(set) var isPairing = false

    private let credentialStore: any PuckCredentialStoring
    private let defaults: UserDefaults
    private let pairerFactory: PuckPairerFactory
    private let engineFactory: PuckEngineFactory
    private var engine: (any PuckProtectionServing)?
    private var eventTask: Task<Void, Never>?

    public init(
        credentialStore: any PuckCredentialStoring = PuckCredentialStore(),
        defaults: UserDefaults = .standard,
        pairerFactory: @escaping PuckPairerFactory = { url in
            PuckAPI(serverURL: url, token: nil)
        },
        engineFactory: @escaping PuckEngineFactory = { url, token in
            PuckProtectionEngine(api: PuckAPI(serverURL: url, token: token))
        }
    ) {
        let storedServerURL = defaults.string(forKey: Self.serverURLKey)
        let initialServerURL = storedServerURL == Self.retiredServerURL
            ? Self.defaultServerURL
            : storedServerURL ?? Self.defaultServerURL

        self.credentialStore = credentialStore
        self.defaults = defaults
        self.pairerFactory = pairerFactory
        self.engineFactory = engineFactory
        self.serverURLText = initialServerURL
        self.displayName = defaults.string(forKey: Self.displayNameKey) ?? "Mac puck"
        self.state = .disconnected

        if storedServerURL == Self.retiredServerURL {
            defaults.set(Self.defaultServerURL, forKey: Self.serverURLKey)
        }

        do {
            if let credential = try credentialStore.load(),
               let url = Self.validServerURL(serverURLText) {
                state = .ready
                configureEngine(url: url, credential: credential)
            } else {
                state = .disconnected
            }
        } catch {
            state = .error(message: String(describing: error), retryEndSessionID: nil)
        }
    }

    deinit {
        eventTask?.cancel()
    }

    public func pair() async {
        let code = pairingCode.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let urlText = serverURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = Self.validServerURL(urlText),
              Self.isSixDigitCode(code),
              !name.isEmpty else {
            state = .error(
                message: "Use an HTTPS server URL, a six-digit invitation code, and a puck name.",
                retryEndSessionID: nil
            )
            return
        }

        isPairing = true
        defer { isPairing = false }
        do {
            let paired = try await pairerFactory(url).pair(code: code, displayName: name)
            let credential = PuckCredential(
                puckID: paired.puckID,
                familyID: paired.familyID,
                displayName: paired.displayName,
                accessToken: paired.accessToken
            )
            try credentialStore.save(credential)
            defaults.set(urlText, forKey: Self.serverURLKey)
            defaults.set(name, forKey: Self.displayNameKey)
            serverURLText = urlText
            displayName = name
            pairingCode = ""
            configureEngine(url: url, credential: credential)
            _ = PuckControllerReducer.reduce(state: &state, event: .paired)
        } catch {
            state = .error(message: String(describing: error), retryEndSessionID: nil)
        }
    }

    public func start() async {
        guard await refreshCredentialIfNeeded() else { return }
        await perform(PuckControllerReducer.reduce(state: &state, event: .startTapped))
    }

    public func end() async {
        await perform(PuckControllerReducer.reduce(state: &state, event: .endTapped))
    }

    public func toggleFromShortcut() async {
        if state == .ready {
            guard await refreshCredentialIfNeeded() else { return }
        }
        await perform(PuckControllerReducer.reduce(state: &state, event: .shortcutToggled))
    }

    public func retryEnd() async {
        await perform(PuckControllerReducer.reduce(state: &state, event: .retryTapped))
    }

    public func rePair() {
        do {
            try credentialStore.clear()
            eventTask?.cancel()
            eventTask = nil
            engine = nil
            transcriptLines = []
            latestWarning = nil
            _ = PuckControllerReducer.reduce(state: &state, event: .rePairTapped)
        } catch {
            state = .error(message: String(describing: error), retryEndSessionID: nil)
        }
    }

    private func refreshCredentialIfNeeded() async -> Bool {
        do {
            guard let credential = try credentialStore.load() else {
                eventTask?.cancel()
                eventTask = nil
                engine = nil
                _ = PuckControllerReducer.reduce(state: &state, event: .credentialMissing)
                return false
            }
            if engine == nil, let url = Self.validServerURL(serverURLText) {
                configureEngine(url: url, credential: credential)
            }
            return engine != nil
        } catch {
            state = .error(message: String(describing: error), retryEndSessionID: nil)
            return false
        }
    }

    private func configureEngine(url: URL, credential: PuckCredential) {
        eventTask?.cancel()
        let newEngine = engineFactory(url, credential.accessToken)
        engine = newEngine
        eventTask = Task { [weak self] in
            for await event in newEngine.events {
                guard let self else { return }
                self.project(event)
            }
        }
    }

    private func perform(_ effect: PuckControllerEffect?) async {
        guard let effect, let engine else { return }
        do {
            switch effect {
            case .start:
                transcriptLines = []
                latestWarning = nil
                try await engine.start(callID: UUID(), startedAt: .now)
            case .end:
                try await engine.end()
            case .retryEnd:
                try await engine.retryEnd()
            case .clearCredential:
                return
            }
        } catch {
            _ = PuckControllerReducer.reduce(
                state: &state,
                event: .engineState(.error(String(describing: error)))
            )
        }
    }

    private func project(_ event: PuckProtectionEvent) {
        switch event {
        case .state(let engineState):
            _ = PuckControllerReducer.reduce(state: &state, event: .engineState(engineState))
        case .transcript(let line):
            transcriptLines.append(line)
        case .partialTranscript:
            break
        case .warning(let severity, let warning):
            latestWarning = warning
            _ = PuckControllerReducer.reduce(
                state: &state,
                event: .warning(severity: severity, warning: warning)
            )
        }
    }

    private static func validServerURL(_ text: String) -> URL? {
        guard let components = URLComponents(string: text),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              let url = components.url else { return nil }
        return url
    }

    private static func isSixDigitCode(_ code: String) -> Bool {
        code.utf8.count == 6 && code.utf8.allSatisfy { (48...57).contains($0) }
    }
}
