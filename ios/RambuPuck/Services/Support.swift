import AVFoundation
import Foundation
import Network

// MARK: - Penyimpanan lokal

/// Semua yang perlu diingat HP ini setelah app ditutup. Disimpan sebagai JSON di Application Support.
/// Tidak ada akun atau server: data keluarga dan riwayat hanya ada di HP ini.
struct SavedState: Codable, Equatable {
    var onboardingComplete: Bool
    var persona: Persona
    var parent: Person
    var guardians: [Person]
    /// Orang tua lain yang dijaga pengawas selain `parent`.
    var extraParents: [Person]
    var history: [CallRecord]
    var puck: PuckState
    var narrationEnabled: Bool
    var language: AppLanguage = .indonesian

    private enum CodingKeys: String, CodingKey {
        case onboardingComplete, persona, parent, guardians, extraParents, history, puck
        case narrationEnabled, language
    }

    init(
        onboardingComplete: Bool,
        persona: Persona,
        parent: Person,
        guardians: [Person],
        extraParents: [Person],
        history: [CallRecord],
        puck: PuckState,
        narrationEnabled: Bool,
        language: AppLanguage = .indonesian
    ) {
        self.onboardingComplete = onboardingComplete
        self.persona = persona
        self.parent = parent
        self.guardians = guardians
        self.extraParents = extraParents
        self.history = history
        self.puck = puck
        self.narrationEnabled = narrationEnabled
        self.language = language
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        onboardingComplete = try values.decode(Bool.self, forKey: .onboardingComplete)
        persona = try values.decode(Persona.self, forKey: .persona)
        parent = try values.decode(Person.self, forKey: .parent)
        guardians = try values.decode([Person].self, forKey: .guardians)
        extraParents = try values.decode([Person].self, forKey: .extraParents)
        history = try values.decode([CallRecord].self, forKey: .history)
        puck = try values.decode(PuckState.self, forKey: .puck)
        narrationEnabled = try values.decode(Bool.self, forKey: .narrationEnabled)
        language = try values.decodeIfPresent(AppLanguage.self, forKey: .language) ?? .indonesian
    }
}

struct LocalStore: Sendable {
    let url: URL

    static var standard: LocalStore {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Rambu", isDirectory: true)
        return LocalStore(url: folder.appendingPathComponent("state.json"))
    }

    func load() -> SavedState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SavedState.self, from: data)
    }

    func save(_ state: SavedState) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(state) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic, .completeFileProtection])
    }

    func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - Narasi suara

/// Membacakan teks pendek dalam bahasa Indonesia, untuk orang tua yang lebih nyaman mendengar.
@MainActor
final class Narrator {
    private let synthesizer = AVSpeechSynthesizer()
    private let enabled: Bool

    init(enabled: Bool) {
        self.enabled = enabled
    }

    func speak(_ text: String, language: AppLanguage = .indonesian) {
        guard enabled else { return }
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: language.speechCode)
        utterance.rate = 0.46
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }
}

// MARK: - Internet

/// Memantau koneksi internet supaya beranda bisa memberi tahu kalau pengawas tidak bisa dikabari.
@MainActor
final class NetworkMonitor {
    private let monitor = NWPathMonitor()
    var onChange: ((Bool) -> Void)?

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.onChange?(online) }
        }
        monitor.start(queue: DispatchQueue(label: "rambu.network"))
    }
}

// MARK: - Tautan undangan

/// Tautan undangan pengawas. Bentuk https supaya bisa diketuk di WhatsApp;
/// halaman web di alamat itu meneruskan ke `rambu://gabung?kode=…` (atau jadi Universal Link).
enum InviteLink {
    static let webBase = "https://rambu-saku.vercel.app/gabung"
    static let scheme = "rambu"

    static func url(code: String) -> URL {
        URL(string: "\(webBase)?kode=\(code)")!
    }

    static func message(code: String, parentName: String, expiresAt: Date? = nil) -> String {
        let expiry = expiresAt.map { " Kode berlaku sampai pukul \(Fmt.clock($0))." } ?? ""
        return "\(parentName) mengundang Anda menjadi pendamping di Rambu. Kode undangan: \(code). Buka Rambu, pilih Saya pendamping, lalu masukkan kode ini.\(expiry)"
    }

    static func whatsAppURL(code: String, parentName: String) -> URL {
        var components = URLComponents(string: "https://wa.me/")!
        components.queryItems = [URLQueryItem(name: "text", value: message(code: code, parentName: parentName))]
        return components.url!
    }

    /// Menerima `rambu://gabung?kode=482913` maupun tautan https di atas.
    static func code(from url: URL) -> String? {
        let isApp = url.scheme == scheme && url.host == "gabung"
        let isWeb = url.absoluteString.hasPrefix(webBase)
        guard isApp || isWeb else { return nil }
        let code = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "kode" }?.value?
            .filter(\.isNumber)
        guard let code, code.count == 6 else { return nil }
        return code
    }
}

// MARK: - Umpan balik deteksi

/// Keputusan "Aman" dari pengawas berarti peringatan itu keliru. Dicatat supaya model deteksi
/// (Langflow) bisa diperbaiki. Nyata: POST /feedback ke backend.
@MainActor
protocol DetectionFeedback: AnyObject {
    func reportFalsePositive(alertID: UUID, signals: [SignalKind])
}

@MainActor
final class LocalDetectionFeedback: DetectionFeedback {
    private(set) var reported: [UUID] = []

    func reportFalsePositive(alertID: UUID, signals: [SignalKind]) {
        if !reported.contains(alertID) { reported.append(alertID) }
    }
}
